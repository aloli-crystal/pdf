module PDF
  module Raster
    # Évalue une fonction PDF (ISO 32000-1 § 7.10) : type 2
    # (interpolation exponentielle), type 3 (raccordement/stitching) et
    # type 0 (échantillonnée, 1 entrée). Sert au calcul des couleurs des
    # dégradés. Le type 4 (calculatrice PostScript) n'est pas géré.
    class PdfFunction
      def initialize(@type : Int32)
        @c0 = [0.0]
        @c1 = [1.0]
        @n = 1.0
        @domain = [0.0, 1.0]
        @functions = [] of PdfFunction
        @bounds = [] of Float64
        @encode = [] of Float64
        # type 0
        @size = 0
        @bps = 8
        @range = [] of Float64
        @samples = Bytes.empty
        @decode = [] of Float64
      end

      # Construit une (ou plusieurs) fonctions depuis un objet PDF :
      # un dictionnaire/flux, ou un tableau de fonctions mono-sortie.
      def self.parse(reader : PDF::Reader, obj : PDF::Objects::Base?) : Array(PdfFunction)
        return [] of PdfFunction unless obj
        resolved = reader.resolve(obj)
        if arr = resolved.as?(PDF::Objects::Array)
          return arr.compact_map { |e| parse_one(reader, e) }
        end
        f = parse_one(reader, obj)
        f ? [f] : [] of PdfFunction
      end

      private def self.parse_one(reader : PDF::Reader, obj : PDF::Objects::Base?) : PdfFunction?
        return unless obj
        resolved = reader.resolve(obj)
        dict = resolved.as?(PDF::Objects::Dictionary) || resolved.as?(PDF::Objects::Stream).try(&.dictionary)
        return unless dict
        type = int(reader, dict["FunctionType"]?) || 2
        fn = PdfFunction.new(type)
        fn.load(reader, dict, resolved.as?(PDF::Objects::Stream))
        fn
      end

      protected def load(reader : PDF::Reader, dict : PDF::Objects::Dictionary, stream : PDF::Objects::Stream?) : Nil
        @domain = floats(reader, dict["Domain"]?) || [0.0, 1.0]
        case @type
        when 2
          @c0 = floats(reader, dict["C0"]?) || [0.0]
          @c1 = floats(reader, dict["C1"]?) || [1.0]
          @n = (reader.resolve(dict["N"]? || PDF::Objects::Number.new(1)).as?(PDF::Objects::Number).try(&.to_f64)) || 1.0
        when 3
          @functions = PdfFunction.parse(reader, dict["Functions"]?)
          @bounds = floats(reader, dict["Bounds"]?) || [] of Float64
          @encode = floats(reader, dict["Encode"]?) || [] of Float64
        when 0
          if stream
            @samples = stream.data
            @size = (floats(reader, dict["Size"]?) || [2.0]).first.to_i
            @bps = int(reader, dict["BitsPerSample"]?) || 8
            @range = floats(reader, dict["Range"]?) || [] of Float64
            @encode = floats(reader, dict["Encode"]?) || [0.0, (@size - 1).to_f]
            @decode = floats(reader, dict["Decode"]?) || @range
          end
        end
      end

      # Évalue la fonction en `t`, renvoyant les composantes de couleur.
      def eval(t : Float64) : Array(Float64)
        t = t.clamp(@domain[0], @domain[1]? || 1.0)
        case @type
        when 2 then eval_exponential(t)
        when 3 then eval_stitching(t)
        when 0 then eval_sampled(t)
        else        [t]
        end
      end

      private def eval_exponential(t : Float64) : Array(Float64)
        tn = @n == 1.0 ? t : t ** @n
        (0...@c0.size).map { |i| @c0[i] + tn * ((@c1[i]? || 0.0) - @c0[i]) }
      end

      private def eval_stitching(t : Float64) : Array(Float64)
        return [t] if @functions.empty?
        k = 0
        while k < @bounds.size && t >= @bounds[k]
          k += 1
        end
        k = @functions.size - 1 if k >= @functions.size
        lo = k == 0 ? @domain[0] : @bounds[k - 1]
        hi = k == @bounds.size ? (@domain[1]? || 1.0) : @bounds[k]
        e0 = @encode[2 * k]? || 0.0
        e1 = @encode[2 * k + 1]? || 1.0
        tt = hi > lo ? e0 + (t - lo) * (e1 - e0) / (hi - lo) : e0
        @functions[k].eval(tt)
      end

      private def eval_sampled(t : Float64) : Array(Float64)
        return [t] if @samples.empty? || @size < 2
        d0 = @domain[0]
        d1 = @domain[1]? || 1.0
        e0 = @encode[0]? || 0.0
        e1 = @encode[1]? || (@size - 1).to_f
        x = d1 > d0 ? e0 + (t - d0) * (e1 - e0) / (d1 - d0) : e0
        x = x.clamp(0.0, (@size - 1).to_f)
        n_out = @range.size // 2
        n_out = 1 if n_out < 1
        i0 = x.floor.to_i
        frac = x - i0
        i1 = Math.min(i0 + 1, @size - 1)
        (0...n_out).map do |c|
          s0 = sample(i0 * n_out + c)
          s1 = sample(i1 * n_out + c)
          v = s0 + frac * (s1 - s0)
          dmin = @decode[2 * c]? || 0.0
          dmax = @decode[2 * c + 1]? || 1.0
          dmin + v * (dmax - dmin)
        end
      end

      private def sample(index : Int32) : Float64
        max = (1 << @bps) - 1
        case @bps
        when 8
          (@samples[index]? || 0_u8).to_f / max
        when 16
          hi = @samples[index * 2]? || 0_u8
          lo = @samples[index * 2 + 1]? || 0_u8
          ((hi.to_i << 8) | lo.to_i).to_f / max
        else
          # bits arbitraires
          bit = index * @bps
          v = 0
          @bps.times do |b|
            byte = @samples[(bit + b) // 8]? || 0_u8
            v = (v << 1) | ((byte >> (7 - ((bit + b) % 8))) & 1)
          end
          v.to_f / max
        end
      end

      protected def self.int(reader, obj) : Int32?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Number).try(&.to_i64.to_i)
      end

      protected def self.floats(reader, obj) : Array(Float64)?
        return unless obj
        arr = reader.resolve(obj).as?(PDF::Objects::Array)
        return unless arr
        arr.compact_map { |e| reader.resolve(e).as?(PDF::Objects::Number).try(&.to_f64) }
      end

      private def floats(reader, obj) : Array(Float64)?
        PdfFunction.floats(reader, obj)
      end

      private def int(reader, obj) : Int32?
        PdfFunction.int(reader, obj)
      end
    end

    # Rend un dégradé (shading dict, ISO 32000-1 § 8.7.4.5) sur la toile :
    # axial (type 2) et radial (type 3). Échantillonne chaque pixel du
    # détourage courant, projette en espace shading via la CTM inverse,
    # calcule le paramètre du dégradé puis la couleur via les fonctions.
    module Shading
      def self.render(canvas : Canvas, reader : PDF::Reader, dict : PDF::Objects::Dictionary, ctm : Matrix, clip : Tuple(Int32, Int32, Int32, Int32)?) : Nil
        type = int(reader, dict["ShadingType"]?)
        return unless type == 2 || type == 3
        coords = floats(reader, dict["Coords"]?)
        return unless coords
        funcs = PdfFunction.parse(reader, dict["Function"]?)
        return if funcs.empty?
        comps = color_components(reader, dict["ColorSpace"]?)
        domain = floats(reader, dict["Domain"]?) || [0.0, 1.0]
        extend_arr = bools(reader, dict["Extend"]?)
        ext0 = extend_arr[0]? || false
        ext1 = extend_arr[1]? || false

        inv = ctm.inverse
        x0 = clip ? Math.max(clip[0], 0) : 0
        y0 = clip ? Math.max(clip[1], 0) : 0
        x1 = clip ? Math.min(clip[2], canvas.width - 1) : canvas.width - 1
        y1 = clip ? Math.min(clip[3], canvas.height - 1) : canvas.height - 1

        (y0..y1).each do |py|
          (x0..x1).each do |px|
            ux, uy = inv.apply(px + 0.5, py + 0.5)
            t = type == 2 ? axial_param(coords, ux, uy, ext0, ext1) : radial_param(coords, ux, uy, ext0, ext1)
            next unless t
            tt = domain[0] + t * ((domain[1]? || 1.0) - domain[0])
            rgb = to_rgb(eval_color(funcs, tt), comps)
            canvas.blend(px, py, rgb[0], rgb[1], rgb[2], 1.0)
          end
        end
      end

      # Projette (ux,uy) sur l'axe [x0 y0 x1 y1] → t ∈ [0,1] (ou nil si
      # hors limites sans extension).
      private def self.axial_param(c : Array(Float64), ux : Float64, uy : Float64, ext0 : Bool, ext1 : Bool) : Float64?
        ax = c[0]; ay = c[1]; bx = c[2]; by = c[3]
        dx = bx - ax; dy = by - ay
        len2 = dx * dx + dy * dy
        return 0.0 if len2 == 0
        t = ((ux - ax) * dx + (uy - ay) * dy) / len2
        if t < 0
          return unless ext0
          t = 0.0
        elsif t > 1
          return unless ext1
          t = 1.0
        end
        t
      end

      # Paramètre du dégradé radial entre les cercles (x0,y0,r0) et
      # (x1,y1,r1) : cherche le plus grand s ∈ [0,1] dont le cercle
      # interpolé passe par (ux,uy).
      private def self.radial_param(c : Array(Float64), ux : Float64, uy : Float64, ext0 : Bool, ext1 : Bool) : Float64?
        x0 = c[0]; y0 = c[1]; r0 = c[2]; x1 = c[3]; y1 = c[4]; r1 = c[5]
        cdx = x1 - x0; cdy = y1 - y0; dr = r1 - r0
        a = cdx * cdx + cdy * cdy - dr * dr
        px = ux - x0; py = uy - y0
        b = 2 * (px * cdx + py * cdy + r0 * dr)
        cc = px * px + py * py - r0 * r0
        best = nil.as(Float64?)
        if a.abs < 1e-9
          s = b.abs < 1e-12 ? nil : cc / b
          best = s if s && (r0 + s * dr) >= 0
        else
          disc = b * b - 4 * a * cc
          if disc >= 0
            sq = Math.sqrt(disc)
            [(b + sq) / (2 * a), (b - sq) / (2 * a)].each do |sol|
              next if (r0 + sol * dr) < 0
              best = sol if best.nil? || sol > best.not_nil!
            end
          end
        end
        return unless best
        s = best.not_nil!
        if s < 0
          return unless ext0
          s = 0.0
        elsif s > 1
          return unless ext1
          s = 1.0
        end
        s
      end

      private def self.eval_color(funcs : Array(PdfFunction), t : Float64) : Array(Float64)
        if funcs.size == 1
          funcs[0].eval(t)
        else
          funcs.map { |f| f.eval(t).first? || 0.0 }
        end
      end

      private def self.to_rgb(comps : Array(Float64), n : Int32) : Tuple(Float64, Float64, Float64)
        case n
        when 1 then {comps[0]? || 0.0, comps[0]? || 0.0, comps[0]? || 0.0}
        when 4 then PDF::Content::Color.cmyk_to_rgb(comps[0]? || 0.0, comps[1]? || 0.0, comps[2]? || 0.0, comps[3]? || 0.0)
        else        {comps[0]? || 0.0, comps[1]? || 0.0, comps[2]? || 0.0}
        end
      end

      private def self.color_components(reader : PDF::Reader, cs : PDF::Objects::Base?) : Int32
        return 3 unless cs
        resolved = reader.resolve(cs)
        case resolved
        when PDF::Objects::Name
          case resolved.value
          when "DeviceGray", "CalGray" then 1
          when "DeviceCMYK"            then 4
          else                              3
          end
        when PDF::Objects::Array
          head = resolved.size > 0 ? reader.resolve(resolved.unsafe_fetch(0)).as?(PDF::Objects::Name).try(&.value) : nil
          if head == "ICCBased" && resolved.size > 1 && (st = reader.resolve(resolved.unsafe_fetch(1)).as?(PDF::Objects::Stream))
            return (int(reader, st["N"]?) || 3)
          end
          3
        else
          3
        end
      end

      private def self.int(reader, obj) : Int32?
        return unless obj
        reader.resolve(obj).as?(PDF::Objects::Number).try(&.to_i64.to_i)
      end

      private def self.floats(reader, obj) : Array(Float64)?
        return unless obj
        arr = reader.resolve(obj).as?(PDF::Objects::Array)
        return unless arr
        arr.compact_map { |e| reader.resolve(e).as?(PDF::Objects::Number).try(&.to_f64) }
      end

      private def self.bools(reader, obj) : Array(Bool)
        return [] of Bool unless obj
        arr = reader.resolve(obj).as?(PDF::Objects::Array)
        return [] of Bool unless arr
        arr.map { |e| reader.resolve(e).as?(PDF::Objects::Boolean).try(&.value) || false }
      end
    end
  end
end
