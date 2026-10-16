require "stumpy_jpeg"

module PDF
  module Raster
    # Composite une image XObject (`/Subtype /Image`) sur la toile,
    # selon la CTM courante (l'image occupe le carré unité [0,1]² de
    # l'espace utilisateur, ISO 32000-1 § 8.9.5).
    #
    # Décodage géré : JPEG (`/DCTDecode`, via stumpy_jpeg), échantillons
    # `/FlateDecode` en DeviceRGB/Gray/CMYK 8 bits, palette `/Indexed`,
    # et masques de pochoir `/ImageMask`. Filtres CCITT/JPX/JBIG2 et
    # profondeurs exotiques : ignorés (l'image n'est pas dessinée).
    module ImagePainter
      # Dessine l'image `stream` sur `canvas` via la transformation `ctm`.
      # `fill` est la couleur courante (utilisée par les ImageMask).
      def self.draw(canvas : Canvas, reader : PDF::Reader, stream : PDF::Objects::Stream, ctm : Matrix, fill : Tuple(Float64, Float64, Float64)) : Nil
        width = int(reader, stream["Width"]?)
        height = int(reader, stream["Height"]?)
        return unless width && height && width > 0 && height > 0

        sampler = build_sampler(reader, stream, width, height, fill)
        return unless sampler

        composite(canvas, sampler, alpha_sampler(reader, stream), ctm)
      rescue
        # image illisible : on l'ignore plutôt que de planter le rendu
      end

      # Construit l'échantillonneur d'alpha à partir du /SMask de
      # l'image (image DeviceGray donnant la transparence par pixel),
      # ou nil si absent.
      private def self.alpha_sampler(reader : PDF::Reader, stream : PDF::Objects::Stream) : Sampler?
        sm = stream["SMask"]?
        return unless sm
        mask = reader.resolve(sm).as?(PDF::Objects::Stream)
        return unless mask
        w = int(reader, mask["Width"]?)
        h = int(reader, mask["Height"]?)
        return unless w && h && w > 0 && h > 0
        filter = filter_name(reader, mask["Filter"]?)
        if filter == "DCTDecode"
          return jpeg_sampler(mask, w, h)
        end
        return unless mask.decoded
        bpc = int(reader, mask["BitsPerComponent"]?) || 8
        return unless bpc == 8
        data = mask.data
        Sampler.new(w, h) do |col, row|
          g = byte_at(data, row * w + col) / 255.0
          {g, g, g}
        end
      end

      # Échantillonneur : renvoie la couleur RGBA d'un pixel image, ou
      # nil (transparent — pour les zones non peintes d'un masque).
      private struct Sampler
        getter width : Int32
        getter height : Int32

        def initialize(@width : Int32, @height : Int32, &block : Int32, Int32 -> Tuple(Float64, Float64, Float64)?)
          @block = block
        end

        def at(col : Int32, row : Int32) : Tuple(Float64, Float64, Float64)?
          @block.call(col, row)
        end
      end

      private def self.composite(canvas : Canvas, sampler : Sampler, alpha : Sampler?, ctm : Matrix) : Nil
        # Boîte englobante en pixels périphérique (coins du carré unité).
        corners = [ctm.apply(0.0, 0.0), ctm.apply(1.0, 0.0), ctm.apply(1.0, 1.0), ctm.apply(0.0, 1.0)]
        min_x = corners.min_of(&.[0]).floor.to_i
        max_x = corners.max_of(&.[0]).ceil.to_i
        min_y = corners.min_of(&.[1]).floor.to_i
        max_y = corners.max_of(&.[1]).ceil.to_i
        min_x = Math.max(min_x, 0)
        min_y = Math.max(min_y, 0)
        max_x = Math.min(max_x, canvas.width - 1)
        max_y = Math.min(max_y, canvas.height - 1)
        return if max_x < min_x || max_y < min_y

        inv = ctm.inverse
        (min_y..max_y).each do |py|
          (min_x..max_x).each do |px|
            u, v = inv.apply(px + 0.5, py + 0.5)
            next if u < 0.0 || u >= 1.0 || v < 0.0 || v >= 1.0
            col = (u * sampler.width).to_i
            row = ((1.0 - v) * sampler.height).to_i # ligne 0 en haut
            col = sampler.width - 1 if col >= sampler.width
            row = sampler.height - 1 if row >= sampler.height
            if rgb = sampler.at(col, row)
              a = 1.0
              if asamp = alpha
                acol = (u * asamp.width).to_i.clamp(0, asamp.width - 1)
                arow = ((1.0 - v) * asamp.height).to_i.clamp(0, asamp.height - 1)
                a = asamp.at(acol, arow).try(&.[0]) || 1.0
              end
              canvas.blend(px, py, rgb[0], rgb[1], rgb[2], a)
            end
          end
        end
      end

      private def self.build_sampler(reader : PDF::Reader, stream : PDF::Objects::Stream, width : Int32, height : Int32, fill : Tuple(Float64, Float64, Float64)) : Sampler?
        if bool(reader, stream["ImageMask"]?)
          return mask_sampler(stream, width, height, fill)
        end

        filter = filter_name(reader, stream["Filter"]?)
        if filter == "DCTDecode"
          return jpeg_sampler(stream, width, height)
        end

        # Échantillons décodés (FlateDecode & co.).
        return unless stream.decoded
        bpc = int(reader, stream["BitsPerComponent"]?) || 8
        return unless bpc == 8 || bpc == 1
        cs = stream["ColorSpace"]?
        raw_sampler(reader, stream, width, height, bpc, cs)
      end

      private def self.jpeg_sampler(stream : PDF::Objects::Stream, width : Int32, height : Int32) : Sampler?
        canvas = StumpyJPEG.read(IO::Memory.new(stream.data))
        Sampler.new(canvas.width, canvas.height) do |col, row|
          px = canvas[col, row]
          {px.r / 65535.0, px.g / 65535.0, px.b / 65535.0}
        end
      rescue
        nil
      end

      private def self.mask_sampler(stream : PDF::Objects::Stream, width : Int32, height : Int32, fill : Tuple(Float64, Float64, Float64)) : Sampler
        data = stream.data
        stride = (width + 7) // 8
        # Décodage par défaut : échantillon 0 → peindre, 1 → transparent.
        Sampler.new(width, height) do |col, row|
          idx = row * stride + (col >> 3)
          bit = idx < data.size ? ((data[idx] >> (7 - (col & 7))) & 1) : 1
          bit == 0 ? fill : nil
        end
      end

      private def self.raw_sampler(reader : PDF::Reader, stream : PDF::Objects::Stream, width : Int32, height : Int32, bpc : Int32, cs : PDF::Objects::Base?) : Sampler?
        data = stream.data
        space, comps, palette = resolve_color_space(reader, cs)
        return unless space

        if space == "indexed"
          pal = palette
          return unless pal
          stride = (width * bpc + 7) // 8
          return Sampler.new(width, height) do |col, row|
            index = read_sample(data, row * stride, col, bpc)
            base = index * 3
            if base + 2 < pal.size
              {pal[base] / 255.0, pal[base + 1] / 255.0, pal[base + 2] / 255.0}
            else
              {0.0, 0.0, 0.0}
            end
          end
        end

        # 8 bits par composante uniquement pour les espaces directs.
        return unless bpc == 8
        stride = width * comps
        Sampler.new(width, height) do |col, row|
          off = row * stride + col * comps
          case comps
          when 1
            g = byte_at(data, off) / 255.0
            {g, g, g}
          when 3
            {byte_at(data, off) / 255.0, byte_at(data, off + 1) / 255.0, byte_at(data, off + 2) / 255.0}
          when 4
            PDF::Content::Color.cmyk_to_rgb(
              byte_at(data, off) / 255.0, byte_at(data, off + 1) / 255.0,
              byte_at(data, off + 2) / 255.0, byte_at(data, off + 3) / 255.0)
          else
            {0.0, 0.0, 0.0}
          end
        end
      end

      # Renvoie {libellé d'espace, composantes, palette éventuelle}.
      private def self.resolve_color_space(reader : PDF::Reader, cs : PDF::Objects::Base?) : Tuple(String?, Int32, Array(UInt8)?)
        return {"gray", 1, nil} unless cs
        resolved = reader.resolve(cs)
        case resolved
        when PDF::Objects::Name
          case resolved.value
          when "DeviceRGB", "RGB", "CalRGB" then {"rgb", 3, nil}
          when "DeviceGray", "G", "CalGray" then {"gray", 1, nil}
          when "DeviceCMYK", "CMYK"         then {"cmyk", 4, nil}
          else                                   {"gray", 1, nil}
          end
        when PDF::Objects::Array
          head = reader.resolve(resolved.unsafe_fetch(0)).as?(PDF::Objects::Name).try(&.value) if resolved.size > 0
          case head
          when "ICCBased"
            n = 3
            if resolved.size > 1 && (st = reader.resolve(resolved.unsafe_fetch(1)).as?(PDF::Objects::Stream))
              n = int(reader, st["N"]?) || 3
            end
            {(n == 1 ? "gray" : (n == 4 ? "cmyk" : "rgb")), n, nil}
          when "Indexed", "I"
            {"indexed", 1, indexed_palette(reader, resolved)}
          else
            {"rgb", 3, nil}
          end
        else
          {"gray", 1, nil}
        end
      end

      # Table de correspondance d'un espace /Indexed, convertie en RGB
      # (3 octets par entrée). Suppose une base RGB/Gray/CMYK.
      private def self.indexed_palette(reader : PDF::Reader, cs : PDF::Objects::Array) : Array(UInt8)?
        return if cs.size < 4
        base_cs = cs.unsafe_fetch(1)
        _, base_comps, _ = resolve_color_space(reader, base_cs)
        lookup = reader.resolve(cs.unsafe_fetch(3))
        raw = case lookup
              when PDF::Objects::Str    then lookup.value.to_slice
              when PDF::Objects::Stream then lookup.data
              else                           return
              end
        entries = raw.size // base_comps
        palette = Array(UInt8).new(entries * 3, 0_u8)
        (0...entries).each do |i|
          off = i * base_comps
          r, g, b = case base_comps
                    when 1
                      v = raw[off]
                      {v, v, v}
                    when 4
                      rgb = PDF::Content::Color.cmyk_to_rgb(raw[off] / 255.0, raw[off + 1] / 255.0, raw[off + 2] / 255.0, raw[off + 3] / 255.0)
                      {(rgb[0] * 255).to_u8, (rgb[1] * 255).to_u8, (rgb[2] * 255).to_u8}
                    else
                      {raw[off], raw[off + 1]? || 0_u8, raw[off + 2]? || 0_u8}
                    end
          palette[i * 3] = r
          palette[i * 3 + 1] = g
          palette[i * 3 + 2] = b
        end
        palette
      end

      private def self.read_sample(data : Bytes, row_off : Int32, col : Int32, bpc : Int32) : Int32
        case bpc
        when 8 then byte_at(data, row_off + col).to_i
        when 1
          idx = row_off + (col >> 3)
          idx < data.size ? ((data[idx] >> (7 - (col & 7))) & 1).to_i : 0
        else
          0
        end
      end

      private def self.byte_at(data : Bytes, i : Int32) : UInt8
        i >= 0 && i < data.size ? data[i] : 0_u8
      end

      private def self.int(reader : PDF::Reader, obj : PDF::Objects::Base?) : Int32?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Number).try(&.to_i64.to_i)
      end

      private def self.bool(reader : PDF::Reader, obj : PDF::Objects::Base?) : Bool
        return false unless obj
        reader.resolve(obj).as?(PDF::Objects::Boolean).try(&.value) || false
      end

      private def self.filter_name(reader : PDF::Reader, obj : PDF::Objects::Base?) : String?
        return unless obj
        resolved = reader.resolve(obj)
        case resolved
        when PDF::Objects::Name  then resolved.value
        when PDF::Objects::Array then resolved.size > 0 ? reader.resolve(resolved.unsafe_fetch(resolved.size - 1)).as?(PDF::Objects::Name).try(&.value) : nil
        end
      end
    end
  end
end
