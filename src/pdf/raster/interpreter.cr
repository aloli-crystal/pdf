module PDF
  module Raster
    # Interprète un flux de contenu PDF et peint le résultat sur une
    # `Canvas`. Couvre : chemins (construction, remplissage even-odd/
    # non-zéro, trait avec tirets et jointures rondes), état graphique
    # (q/Q/cm/w/d), couleurs Device (gray/RGB/CMYK), **texte** (glyphes
    # TrueType et CFF/Type1C), **images** (Do, XObjects image + masques
    # doux), Form XObjects (récursifs), **détourage exact** (W/W*) et
    # **dégradés** (sh + motifs de remplissage shading).
    #
    # Hors périmètre : images en ligne (BI/ID/EI sautées), fontes Type1
    # PostScript brutes (sans CFF), shadings maillés, modes de fusion.
    class Interpreter
      alias Point = Tuple(Float64, Float64)

      # Région de détourage : boîte englobante (device, en pixels) +
      # masque de couverture optionnel pour les formes non rectangulaires.
      record ClipRegion,
        bbox : Tuple(Float64, Float64, Float64, Float64),
        mask : Bytes? = nil

      # État graphique courant (pile via q/Q). Inclut les paramètres de
      # texte, qui sont sauvegardés/restaurés par q/Q (ISO 32000-1 § 9.3).
      private struct State
        property ctm : Matrix
        property fill : Tuple(Float64, Float64, Float64)
        property stroke : Tuple(Float64, Float64, Float64)
        property line_width : Float64
        property font : Font?
        property font_size : Float64
        property char_spacing : Float64
        property word_spacing : Float64
        property h_scale : Float64
        property leading : Float64
        property rise : Float64
        property render_mode : Int32
        # Région de détourage courante, nil = aucune.
        property clip : ClipRegion?
        # Motif de tireté (longueurs en espace utilisateur) + décalage.
        property dash : Array(Float64)
        property dash_phase : Float64
        # Motif de remplissage (nom de ressource /Pattern) + l'espace de
        # remplissage courant est-il /Pattern ?
        property fill_pattern : String?
        property fill_cs_pattern : Bool

        def initialize(@ctm : Matrix, @fill = {0.0, 0.0, 0.0}, @stroke = {0.0, 0.0, 0.0}, @line_width = 1.0,
                       @font = nil, @font_size = 0.0, @char_spacing = 0.0, @word_spacing = 0.0,
                       @h_scale = 1.0, @leading = 0.0, @rise = 0.0, @render_mode = 0, @clip = nil,
                       @dash = [] of Float64, @dash_phase = 0.0, @fill_pattern = nil, @fill_cs_pattern = false)
        end

        def dup_state : State
          State.new(@ctm, @fill, @stroke, @line_width, @font, @font_size, @char_spacing,
            @word_spacing, @h_scale, @leading, @rise, @render_mode, @clip, @dash, @dash_phase,
            @fill_pattern, @fill_cs_pattern)
        end
      end

      BEZIER_STEPS = 18

      # Tableau en cours de collecte (entre `[` et `]`), nil sinon.
      @array : Array(ContentLexer::Token)?

      def initialize(@canvas : Canvas, base_ctm : Matrix, @reader : PDF::Reader? = nil, @resources : PDF::Objects::Dictionary? = nil, @depth : Int32 = 0)
        @base_ctm = base_ctm
        @state = State.new(base_ctm)
        @stack = [] of State
        @path = [] of Canvas::SubPath
        @subpath = [] of Point
        @current = {0.0, 0.0}
        @start = {0.0, 0.0}
        @nums = [] of Float64
        @last_name = ""
        @last_string = Bytes.empty
        @array = nil
        @last_array = [] of ContentLexer::Token
        @text_matrix = Matrix.identity
        @text_line_matrix = Matrix.identity
        @fonts = {} of String => Font?
        @pending_clip = false
      end

      def run(data : Bytes) : Nil
        ContentLexer.tokenize(data).each { |tok| handle(tok) }
      end

      private def handle(tok : ContentLexer::Token) : Nil
        case tok.kind
        when :num
          if a = @array
            a << tok
          else
            @nums << tok.num
          end
        when :str
          if a = @array
            a << tok
          else
            @last_string = tok.bytes
          end
        when :name
          @last_name = tok.text unless @array
        when :array_start
          @array = [] of ContentLexer::Token
        when :array_end
          if arr = @array
            @last_array = arr
            @array = nil
          end
        when :op
          execute(tok.text)
          @nums.clear
        else
          # délimiteurs de dict : ignorés
        end
      end

      private def execute(op : String) : Nil
        case op
        when "q"  then @stack << @state.dup_state
        when "Q"  then @state = @stack.pop? || @state
        when "cm" then concat_matrix
        when "w"  then @state.line_width = arg(0)
        when "d"  then set_dash
        when "m"  then move_to(arg(0), arg(1))
        when "l"  then line_to(arg(0), arg(1))
        when "c"  then curve_to(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
        when "v"  then curve_to(@current[0], @current[1], arg(0), arg(1), arg(2), arg(3), pre_transformed: true)
        when "y"  then curve_to(arg(0), arg(1), arg(2), arg(3), arg(2), arg(3))
        when "re" then rectangle(arg(0), arg(1), arg(2), arg(3))
        when "h"  then close_subpath
        when "n"  then flush_subpath; apply_pending_clip; end_path
        when "W", "W*"
          @pending_clip = true # prend effet après le prochain opérateur de peinture
        when "f", "F", "f*" then paint(fill: true, stroke: false, even_odd: op == "f*")
        when "S"            then paint(fill: false, stroke: true, even_odd: false)
        when "s"            then close_subpath; paint(fill: false, stroke: true, even_odd: false)
        when "B", "B*"      then paint(fill: true, stroke: true, even_odd: op == "B*")
        when "b", "b*"      then close_subpath; paint(fill: true, stroke: true, even_odd: op == "b*")
        when "g"            then set_fill_color(gray(arg(0)))
        when "G"            then @state.stroke = gray(arg(0))
        when "rg"           then set_fill_color({arg(0), arg(1), arg(2)})
        when "RG"           then @state.stroke = {arg(0), arg(1), arg(2)}
        when "k"            then set_fill_color(cmyk(arg(0), arg(1), arg(2), arg(3)))
        when "K"            then @state.stroke = cmyk(arg(0), arg(1), arg(2), arg(3))
        when "cs"           then @state.fill_cs_pattern = (@last_name == "Pattern")
        when "sc", "scn"
          if @state.fill_cs_pattern
            @state.fill_pattern = @last_name
          else
            set_fill_color(color_from_components)
          end
        when "SC", "SCN" then @state.stroke = color_from_components
          # --- texte ---
        when "BT" then @text_matrix = Matrix.identity; @text_line_matrix = Matrix.identity
        when "ET" then nil # fin de bloc texte
        when "Tf" then set_font
        when "Td" then text_move(arg(0), arg(1))
        when "TD" then @state.leading = -arg(1); text_move(arg(0), arg(1))
        when "Tm" then set_text_matrix
        when "T*" then text_move(0.0, -@state.leading)
        when "TL" then @state.leading = arg(0)
        when "Tc" then @state.char_spacing = arg(0)
        when "Tw" then @state.word_spacing = arg(0)
        when "Tz" then @state.h_scale = arg(0) / 100.0
        when "Ts" then @state.rise = arg(0)
        when "Tr" then @state.render_mode = arg(0).to_i
        when "Tj" then show_text(@last_string)
        when "TJ" then show_text_array
        when "'"  then text_move(0.0, -@state.leading); show_text(@last_string)
        when "\"" then @state.word_spacing = arg(0); @state.char_spacing = arg(1); text_move(0.0, -@state.leading); show_text(@last_string)
        when "Do" then do_xobject
        when "sh" then do_shading
        else
          # opérateur non géré : ignoré
        end
      end

      # Opérateur `sh` : peint un dégradé sur le détourage courant.
      private def do_shading : Nil
        reader = @reader
        res = @resources
        return unless reader && res
        shadings = res["Shading"]?
        shadings = reader.resolve(shadings) if shadings
        dict = shadings.as?(PDF::Objects::Dictionary)
        return unless dict
        entry = dict[@last_name]?
        return unless entry
        resolved = reader.resolve(entry)
        sh = resolved.as?(PDF::Objects::Dictionary) || resolved.as?(PDF::Objects::Stream).try(&.dictionary)
        return unless sh
        sync_clip
        rect = clip_rect
        Shading.render(@canvas, reader, sh, @state.ctm, rect)
      end

      # Boîte de détourage en pixels (Int), ou nil si pas de clip.
      private def clip_rect : Tuple(Int32, Int32, Int32, Int32)?
        clip = @state.clip
        return unless clip
        bb = clip.bbox
        {bb[0].floor.to_i, bb[1].floor.to_i, bb[2].ceil.to_i, bb[3].ceil.to_i}
      end

      # --- XObjects (images et forms) ---

      private def do_xobject : Nil
        reader = @reader
        res = @resources
        return unless reader && res
        xobjects = res["XObject"]?
        xobjects = reader.resolve(xobjects) if xobjects
        dict = xobjects.as?(PDF::Objects::Dictionary)
        return unless dict
        entry = dict[@last_name]?
        return unless entry
        stream = reader.resolve(entry).as?(PDF::Objects::Stream)
        return unless stream

        subtype = stream["Subtype"]?.try { |s| reader.resolve(s).as?(PDF::Objects::Name).try(&.value) }
        case subtype
        when "Image"
          sync_clip
          ImagePainter.draw(@canvas, reader, stream, @state.ctm, @state.fill)
        when "Form"
          run_form(reader, stream)
        end
      end

      private def run_form(reader : PDF::Reader, stream : PDF::Objects::Stream) : Nil
        return if @depth >= 8
        form_ctm = form_matrix(reader, stream).then(@state.ctm)
        form_res = stream["Resources"]?
        form_res = reader.resolve(form_res) if form_res
        res = form_res.as?(PDF::Objects::Dictionary) || @resources
        child = Interpreter.new(@canvas, form_ctm, reader, res, @depth + 1)
        child.inherit_fill(@state.fill)
        child.run(stream.data)
      end

      # Hérite la couleur de remplissage courante (les forms héritent de
      # l'état graphique de l'appelant).
      protected def inherit_fill(color : Tuple(Float64, Float64, Float64)) : Nil
        @state.fill = color
      end

      private def form_matrix(reader : PDF::Reader, stream : PDF::Objects::Stream) : Matrix
        m = stream["Matrix"]?
        m = reader.resolve(m) if m
        if arr = m.as?(PDF::Objects::Array)
          if arr.size == 6
            v = arr.map { |e| reader.resolve(e).as?(PDF::Objects::Number).try(&.to_f64) || 0.0 }
            return Matrix.new(v[0], v[1], v[2], v[3], v[4], v[5])
          end
        end
        Matrix.identity
      end

      # --- Chemins ---

      private def move_to(x : Float64, y : Float64) : Nil
        flush_subpath
        @current = @state.ctm.apply(x, y)
        @start = @current
        @subpath = [@current] of Point
      end

      private def line_to(x : Float64, y : Float64) : Nil
        @current = @state.ctm.apply(x, y)
        @subpath << @current
      end

      private def curve_to(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, x3 : Float64, y3 : Float64, pre_transformed : Bool = false) : Nil
        p0 = @current
        p1 = pre_transformed ? {x1, y1} : @state.ctm.apply(x1, y1)
        p2 = @state.ctm.apply(x2, y2)
        p3 = @state.ctm.apply(x3, y3)
        (1..BEZIER_STEPS).each do |i|
          t = i.to_f / BEZIER_STEPS
          @subpath << bezier(p0, p1, p2, p3, t)
        end
        @current = p3
      end

      private def rectangle(x : Float64, y : Float64, w : Float64, h : Float64) : Nil
        flush_subpath
        ctm = @state.ctm
        @subpath = [
          ctm.apply(x, y), ctm.apply(x + w, y),
          ctm.apply(x + w, y + h), ctm.apply(x, y + h),
        ] of Point
        @current = ctm.apply(x, y)
        @start = @current
        flush_subpath
      end

      private def close_subpath : Nil
        return if @subpath.empty?
        @subpath << @start
        @current = @start
      end

      private def flush_subpath : Nil
        @path << @subpath if @subpath.size >= 2
        @subpath = [] of Point
      end

      private def end_path : Nil
        @path.clear
        @subpath = [] of Point
      end

      private def paint(fill : Bool, stroke : Bool, even_odd : Bool) : Nil
        flush_subpath
        if @path.empty?
          apply_pending_clip
          return
        end
        sync_clip
        if fill
          if pat = @state.fill_pattern
            fill_with_pattern(pat, even_odd)
          else
            r, g, b = @state.fill
            @canvas.fill(@path, r, g, b, even_odd)
          end
        end
        if stroke
          r, g, b = @state.stroke
          scale = @state.ctm.mean_scale
          dash = @state.dash.empty? ? nil : @state.dash.map { |d| d * scale }
          @canvas.stroke(@path, @state.line_width * scale, r, g, b,
            dash: dash, dash_phase: @state.dash_phase * scale)
        end
        apply_pending_clip
        end_path
      end

      # Fixe une couleur de remplissage solide (annule tout motif).
      private def set_fill_color(color : Tuple(Float64, Float64, Float64)) : Nil
        @state.fill = color
        @state.fill_pattern = nil
      end

      # Remplit le chemin courant avec un motif de dégradé
      # (PatternType 2). Le dégradé est détouré à la forme du chemin
      # (masque de couverture) et rendu via la matrice du motif.
      private def fill_with_pattern(name : String, even_odd : Bool) : Nil
        reader = @reader
        res = @resources
        return unless reader && res
        patterns = res["Pattern"]?
        patterns = reader.resolve(patterns) if patterns
        pdict = patterns.as?(PDF::Objects::Dictionary)
        return unless pdict
        entry = pdict[name]?
        return unless entry
        resolved = reader.resolve(entry)
        pattern = resolved.as?(PDF::Objects::Dictionary) || resolved.as?(PDF::Objects::Stream).try(&.dictionary)
        return unless pattern
        ptype = pattern["PatternType"]?.try { |t| reader.resolve(t).as?(PDF::Objects::Number).try(&.to_i64.to_i) }
        return unless ptype == 2 # seuls les motifs de dégradé (shading patterns)

        sh_obj = pattern["Shading"]?
        return unless sh_obj
        sh_resolved = reader.resolve(sh_obj)
        shading = sh_resolved.as?(PDF::Objects::Dictionary) || sh_resolved.as?(PDF::Objects::Stream).try(&.dictionary)
        return unless shading

        pattern_ctm = pattern_matrix(reader, pattern).then(@base_ctm)

        # Détoure le dégradé à la forme du chemin (∩ clip courant).
        box = path_bbox(@path)
        return unless box
        old = @state.clip
        new_box = old ? intersect_box(old.bbox, box) : box
        path_mask = @canvas.path_coverage(@path, even_odd)
        mask = combine_masks(old.try(&.mask), path_mask, new_box)
        rect = {new_box[0].floor.to_i, new_box[1].floor.to_i, new_box[2].ceil.to_i, new_box[3].ceil.to_i}
        @canvas.set_clip(rect, mask)
        Shading.render(@canvas, reader, shading, pattern_ctm, rect)
        sync_clip # restaure le détourage de l'état
      end

      private def pattern_matrix(reader : PDF::Reader, pattern : PDF::Objects::Dictionary) : Matrix
        m = pattern["Matrix"]?
        m = reader.resolve(m) if m
        if arr = m.as?(PDF::Objects::Array)
          if arr.size == 6
            v = arr.map { |e| reader.resolve(e).as?(PDF::Objects::Number).try(&.to_f64) || 0.0 }
            return Matrix.new(v[0], v[1], v[2], v[3], v[4], v[5])
          end
        end
        Matrix.identity
      end

      # Opérateur `d` : motif de tireté `[longueurs] phase`.
      private def set_dash : Nil
        @state.dash = @last_array.compact_map { |tok| tok.kind == :num ? tok.num : nil }
        @state.dash_phase = arg(0)
      end

      # Synchronise le détourage de la toile (boîte + masque) sur l'état.
      private def sync_clip : Nil
        clip = @state.clip
        unless clip
          @canvas.set_clip(nil)
          return
        end
        bb = clip.bbox
        rect = {bb[0].floor.to_i, bb[1].floor.to_i, bb[2].ceil.to_i, bb[3].ceil.to_i}
        @canvas.set_clip(rect, clip.mask)
      end

      # Si un W/W* est en attente, intersecte le chemin courant avec la
      # région de détourage. Voie rapide pour les rectangles (boîte
      # seule) ; masque de couverture exact pour les formes complexes.
      private def apply_pending_clip : Nil
        return unless @pending_clip
        @pending_clip = false
        return if @path.empty?
        box = path_bbox(@path)
        return unless box
        old = @state.clip
        new_box = old ? intersect_box(old.bbox, box) : box

        if rectangular?(@path) && (old.nil? || old.mask.nil?)
          @state.clip = ClipRegion.new(new_box, nil) # reste un rectangle
        else
          path_mask = rectangular?(@path) ? nil : @canvas.path_coverage(@path, false)
          @state.clip = ClipRegion.new(new_box, combine_masks(old.try(&.mask), path_mask, new_box))
        end
      end

      private def path_bbox(path : Array(Canvas::SubPath)) : Tuple(Float64, Float64, Float64, Float64)?
        min_x = Float64::INFINITY
        min_y = Float64::INFINITY
        max_x = -Float64::INFINITY
        max_y = -Float64::INFINITY
        path.each do |sp|
          sp.each do |pt|
            min_x = pt[0] if pt[0] < min_x
            min_y = pt[1] if pt[1] < min_y
            max_x = pt[0] if pt[0] > max_x
            max_y = pt[1] if pt[1] > max_y
          end
        end
        min_x.finite? && max_x.finite? ? {min_x, min_y, max_x, max_y} : nil
      end

      private def intersect_box(a : Tuple(Float64, Float64, Float64, Float64), b : Tuple(Float64, Float64, Float64, Float64)) : Tuple(Float64, Float64, Float64, Float64)
        {Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])}
      end

      # Le chemin est-il un unique rectangle aligné sur les axes ?
      private def rectangular?(path : Array(Canvas::SubPath)) : Bool
        return false unless path.size == 1
        sp = path[0]
        return false unless 4 <= sp.size <= 5
        n = sp.size
        n.times do |i|
          a = sp[i]
          b = sp[(i + 1) % n]
          dx = (a[0] - b[0]).abs
          dy = (a[1] - b[1]).abs
          return false unless dx < 0.01 || dy < 0.01
        end
        true
      end

      # Combine (ET) le masque existant et le masque du chemin sur la
      # boîte d'intersection ; renvoie un masque pleine toile.
      private def combine_masks(old_mask : Bytes?, path_mask : Bytes?, box : Tuple(Float64, Float64, Float64, Float64)) : Bytes
        w = @canvas.width
        h = @canvas.height
        mask = Bytes.new(w * h, 0_u8)
        x0 = Math.max(box[0].floor.to_i, 0)
        y0 = Math.max(box[1].floor.to_i, 0)
        x1 = Math.min(box[2].ceil.to_i, w - 1)
        y1 = Math.min(box[3].ceil.to_i, h - 1)
        (y0..y1).each do |py|
          row = py * w
          (x0..x1).each do |px|
            idx = row + px
            o = old_mask ? old_mask[idx] : 255_u8
            p = path_mask ? path_mask[idx] : 255_u8
            mask[idx] = 255_u8 if o != 0 && p != 0
          end
        end
        mask
      end

      # --- Texte ---

      private def set_font : Nil
        @state.font_size = arg(0)
        @state.font = resolve_font(@last_name)
      end

      private def resolve_font(name : String) : Font?
        return @fonts[name] if @fonts.has_key?(name)
        font = nil.as(Font?)
        if (reader = @reader) && (res = @resources)
          fonts_dict = res["Font"]?
          fonts_dict = reader.resolve(fonts_dict) if fonts_dict
          if fd = fonts_dict.as?(PDF::Objects::Dictionary)
            if entry = fd[name]?
              if dict = reader.resolve(entry).as?(PDF::Objects::Dictionary)
                font = Font.load(reader, dict)
              end
            end
          end
        end
        @fonts[name] = font
        font
      end

      private def set_text_matrix : Nil
        @text_line_matrix = Matrix.new(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
        @text_matrix = @text_line_matrix
      end

      private def text_move(tx : Float64, ty : Float64) : Nil
        @text_line_matrix = Matrix.translate(tx, ty).then(@text_line_matrix)
        @text_matrix = @text_line_matrix
      end

      private def show_text_array : Nil
        @last_array.each do |tok|
          case tok.kind
          when :str
            show_text(tok.bytes)
          when :num
            adjust = -tok.num / 1000.0 * @state.font_size * @state.h_scale
            @text_matrix = Matrix.translate(adjust, 0.0).then(@text_matrix)
          end
        end
      end

      private def show_text(bytes : Bytes) : Nil
        font = @state.font
        return unless font
        return if bytes.empty?
        sync_clip
        invisible = @state.render_mode == 3 || @state.render_mode == 7
        fs = @state.font_size
        th = @state.h_scale

        font.decode_to_gids(bytes).each do |gid|
          unless invisible
            param = Matrix.new(fs * th, 0.0, 0.0, fs, 0.0, @state.rise)
            trm = param.then(@text_matrix).then(@state.ctm)
            r, g, b = @state.fill
            contours = font.contours(gid).map do |contour|
              contour.map { |pt| trm.apply(pt[0], pt[1]) }
            end
            @canvas.fill(contours, r, g, b) unless contours.empty?
          end
          # Avance horizontale.
          w0 = font.advance(gid)
          tx = (w0 * fs + @state.char_spacing) * th
          @text_matrix = Matrix.translate(tx, 0.0).then(@text_matrix)
        end
      end

      # --- État & couleurs ---

      private def concat_matrix : Nil
        m = Matrix.new(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
        @state.ctm = m.then(@state.ctm)
      end

      private def gray(v : Float64) : Tuple(Float64, Float64, Float64)
        {v, v, v}
      end

      private def cmyk(c : Float64, m : Float64, y : Float64, k : Float64) : Tuple(Float64, Float64, Float64)
        PDF::Content::Color.cmyk_to_rgb(c, m, y, k)
      end

      private def color_from_components : Tuple(Float64, Float64, Float64)
        case @nums.size
        when 1 then gray(@nums[0])
        when 3 then {@nums[0], @nums[1], @nums[2]}
        when 4 then cmyk(@nums[0], @nums[1], @nums[2], @nums[3])
        else        @state.fill
        end
      end

      private def arg(i : Int32) : Float64
        @nums[i]? || 0.0
      end

      private def bezier(p0 : Point, p1 : Point, p2 : Point, p3 : Point, t : Float64) : Point
        u = 1.0 - t
        a = u * u * u
        b = 3 * u * u * t
        c = 3 * u * t * t
        d = t * t * t
        {
          a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
          a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1],
        }
      end
    end
  end
end
