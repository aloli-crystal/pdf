module PDF
  module Raster
    # Fonte chargée pour le rendu : enveloppe le programme de fonte
    # embarqué d'une fonte PDF et fournit les contours de glyphes, les
    # avances, et le décodage codes → GID.
    #
    # Deux moteurs de glyphes :
    # - **TrueType** (`/FontFile2`, ou OpenType-glyf) via `Raster::Glyph`.
    # - **CFF / Type1C** (`/FontFile3` : Type1C, CIDFontType0C, ou
    #   OpenType-CFF) via `Raster::CFFOutlines` (interpréteur Type 2).
    #
    # Couvre les fontes composites Type0 (Identity-H, 2 octets,
    # `CIDToGIDMap`) et les fontes simples (1 octet, via la table cmap
    # pour le TrueType). Les fontes Type1 PostScript brutes (`/FontFile`,
    # sans CFF) ne sont pas rendues (`load` renvoie nil → texte ignoré).
    class Font
      getter units_per_em : Float64
      getter? two_byte : Bool

      def initialize(
        @two_byte : Bool,
        @cid_to_gid : Array(UInt16)?,
        @truetype : PDF::Fonts::TrueType::Parser? = nil,
        @cff : PDF::Fonts::CFF::Parser? = nil,
      )
        if tt = @truetype
          upm = tt.units_per_em.to_f
          @units_per_em = upm > 0 ? upm : 1000.0
        else
          @units_per_em = 1000.0 # FontMatrix CFF par défaut (0.001)
        end
        @cmap_loaded = false
        @cmap = nil.as(PDF::Fonts::TrueType::Tables::Cmap?)
        @cff_encoding = nil.as(Hash(UInt8, UInt16)?)
        @cache = {} of UInt16 => Tuple(Array(Glyph::Contour), Float64)
      end

      # Charge la fonte de rendu depuis un dictionnaire de fonte PDF.
      # Renvoie nil si aucun programme de fonte exploitable n'est trouvé.
      def self.load(reader : PDF::Reader, font_dict : PDF::Objects::Dictionary) : Font?
        subtype = name_of(reader, font_dict["Subtype"]?)
        descendant = nil.as(PDF::Objects::Dictionary?)
        two_byte = false
        cid_to_gid = nil.as(Array(UInt16)?)

        if subtype == "Type0"
          two_byte = true
          descendant = first_descendant(reader, font_dict)
          return unless descendant
          cid_to_gid = load_cid_to_gid(reader, descendant)
        end

        descriptor = resolve_dict(reader, (descendant || font_dict)["FontDescriptor"]?)
        return unless descriptor

        # TrueType embarqué (/FontFile2).
        if ff2 = stream_of(reader, descriptor["FontFile2"]?)
          parser = PDF::Fonts::TrueType::Parser.parse(ff2.data)
          return Font.new(two_byte, cid_to_gid, truetype: parser) if parser.has_table?("glyf")
        end

        # CFF / Type1C / OpenType (/FontFile3).
        if ff3 = stream_of(reader, descriptor["FontFile3"]?)
          ff3_subtype = name_of(reader, ff3["Subtype"]?)
          if ff3_subtype == "OpenType"
            parser = PDF::Fonts::TrueType::Parser.parse(ff3.data)
            return Font.new(two_byte, cid_to_gid, truetype: parser) if parser.has_table?("glyf")
            if cff_data = parser.table_data("CFF ")
              return Font.new(two_byte, cid_to_gid, cff: PDF::Fonts::CFF::Parser.new(cff_data))
            end
          else
            # Type1C / CIDFontType0C : CFF brut.
            return Font.new(two_byte, cid_to_gid, cff: PDF::Fonts::CFF::Parser.new(ff3.data))
          end
        end

        nil
      rescue
        nil
      end

      # Découpe une chaîne en codes (2 octets pour les fontes composites,
      # 1 octet sinon) puis les traduit en GID.
      def decode_to_gids(bytes : Bytes) : Array(UInt16)
        gids = [] of UInt16
        if two_byte?
          i = 0
          while i + 1 < bytes.size
            code = (bytes[i].to_u32 << 8) | bytes[i + 1].to_u32
            gids << cid_to_gid(code.to_u16)
            i += 2
          end
        else
          bytes.each { |byte| gids << simple_gid(byte) }
        end
        gids
      end

      # Contours du glyphe `gid`, en fraction d'em.
      def contours(gid : UInt16) : Array(Glyph::Contour)
        load_glyph(gid)[0]
      end

      # Avance horizontale du glyphe `gid`, en fraction d'em.
      def advance(gid : UInt16) : Float64
        load_glyph(gid)[1]
      end

      private def load_glyph(gid : UInt16) : Tuple(Array(Glyph::Contour), Float64)
        @cache[gid] ||= begin
          scale = 1.0 / @units_per_em
          if cff = @cff
            raw, width = CFFOutlines.run_glyph(cff, gid.to_i)
            {scale_contours(raw, scale), width * scale}
          elsif tt = @truetype
            raw = Glyph.outline(tt.glyf, tt.loca, gid)
            {scale_contours(raw, scale), truetype_advance(tt, gid) * scale}
          else
            {[] of Glyph::Contour, 0.0}
          end
        end
      end

      private def scale_contours(raw : Array(Glyph::Contour), scale : Float64) : Array(Glyph::Contour)
        raw.map { |c| c.map { |pt| {pt[0] * scale, pt[1] * scale} } }
      end

      private def truetype_advance(tt : PDF::Fonts::TrueType::Parser, gid : UInt16) : Float64
        metrics = tt.hmtx.h_metrics
        return 0.0 if metrics.empty?
        (metrics[gid.to_i]? || metrics.last).advance_width.to_f
      end

      private def cid_to_gid(cid : UInt16) : UInt16
        if map = @cid_to_gid
          map[cid.to_i]? || 0_u16
        else
          cid
        end
      end

      private def simple_gid(code : UInt8) : UInt16
        if cff = @cff
          enc = cff_encoding(cff)
          return enc[code]? || code.to_u16
        end
        cm = cmap
        return code.to_u16 unless cm
        cm.glyph_id(code.to_u32) || cm.glyph_id(0xF000_u32 + code) || 0_u16
      end

      # Construit (et cache) la table Encoding CFF (code → GID) d'une
      # fonte simple, depuis l'opérateur 16 du Top DICT. Gère les formats
      # personnalisés 0 et 1 (ceux que produisent les sous-ensembles).
      private def cff_encoding(cff : PDF::Fonts::CFF::Parser) : Hash(UInt8, UInt16)
        cached = @cff_encoding
        return cached if cached
        map = {} of UInt8 => UInt16
        off = cff.top_dict[16]?.try(&.first?).try(&.to_i) || 0
        data = cff.data
        if off > 1 && off < data.size
          fmt = data[off]
          base = fmt & 0x7F
          if base == 0
            n = data[off + 1].to_i
            (1..n).each do |gid|
              idx = off + 1 + gid
              map[data[idx]] = gid.to_u16 if idx < data.size
            end
          elsif base == 1
            n_ranges = data[off + 1].to_i
            gid = 1
            pos = off + 2
            n_ranges.times do
              break if pos + 1 >= data.size
              first = data[pos].to_i
              n_left = data[pos + 1].to_i
              (0..n_left).each do |k|
                code = first + k
                map[code.to_u8] = gid.to_u16 if code <= 255
                gid += 1
              end
              pos += 2
            end
          end
        end
        @cff_encoding = map
        map
      end

      private def cmap : PDF::Fonts::TrueType::Tables::Cmap?
        return unless tt = @truetype
        unless @cmap_loaded
          @cmap_loaded = true
          @cmap = tt.has_table?("cmap") ? tt.cmap : nil
        end
        @cmap
      end

      private def self.load_cid_to_gid(reader : PDF::Reader, cidfont : PDF::Objects::Dictionary) : Array(UInt16)?
        obj = cidfont["CIDToGIDMap"]?
        return unless obj
        resolved = reader.resolve(obj)
        return unless stream = resolved.as?(PDF::Objects::Stream)
        data = stream.data
        map = Array(UInt16).new(data.size // 2)
        i = 0
        while i + 1 < data.size
          map << ((data[i].to_u16 << 8) | data[i + 1].to_u16)
          i += 2
        end
        map
      end

      private def self.first_descendant(reader : PDF::Reader, font : PDF::Objects::Dictionary) : PDF::Objects::Dictionary?
        desc = font["DescendantFonts"]?
        desc = reader.resolve(desc) if desc
        if arr = desc.as?(PDF::Objects::Array)
          return resolve_dict(reader, arr.unsafe_fetch(0)) if arr.size > 0
        end
        nil
      end

      private def self.stream_of(reader : PDF::Reader, obj : PDF::Objects::Base?) : PDF::Objects::Stream?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Stream)
      end

      private def self.resolve_dict(reader : PDF::Reader, obj : PDF::Objects::Base?) : PDF::Objects::Dictionary?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Dictionary)
      end

      private def self.name_of(reader : PDF::Reader, obj : PDF::Objects::Base?) : String?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Name).try(&.value)
      end
    end
  end
end
