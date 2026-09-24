require "xml"

module PDF
  module SVG
    # Renders an SVG document onto a PDF page.
    #
    # Traverses the SVG element tree and translates each element into
    # corresponding PDF drawing operations.
    #
    # Une seule matrice (CTM) posée au début de `draw` place le dessin
    # sur la page : translation en `at`, échelle vers la taille de
    # sortie, retournement de l'axe y (SVG descend, PDF monte) et
    # origine du viewBox. Tout est ensuite dessiné en unités SVG, les
    # `transform` s'appliquent tels quels par `page.transform`, et les
    # épaisseurs de trait suivent l'échelle d'elles-mêmes.
    #
    # Ported from Prawn::SVG::Renderer.
    class Renderer
      # The PDF page to draw on
      getter page : Page

      # The parsed SVG document
      getter parser : Parser

      # Position to draw the SVG at [x, y] in PDF coordinates
      getter x : Float64
      getter y : Float64

      # Output dimensions
      getter output_width : Float64
      getter output_height : Float64

      # Scale factors
      getter x_scale : Float64
      getter y_scale : Float64

      # Warnings generated during rendering
      getter warnings : Array(String) = [] of String

      # Optional TrueType fonts for `<text>` elements. Without them the
      # standard Helvetica (WinAnsi) is used, which cannot show glyphs
      # outside WinAnsi (≈, →, ■…) : they come out as `?`.
      getter font : Fonts::TrueTypeFont?
      getter bold_font : Fonts::TrueTypeFont?

      def initialize(
        @page : Page,
        @parser : Parser,
        *,
        x : Float64 = 0.0,
        y : Float64 = 0.0,
        width : Float64? = nil,
        height : Float64? = nil,
        @font : Fonts::TrueTypeFont? = nil,
        @bold_font : Fonts::TrueTypeFont? = nil,
      )
        @x = x
        @y = y

        # Calculate output dimensions
        svg_w = parser.width
        svg_h = parser.height

        if vb = parser.viewbox
          svg_w = vb[2] if vb[2] > 0
          svg_h = vb[3] if vb[3] > 0
        end

        @output_width = width || svg_w
        @output_height = height || svg_h

        @x_scale = @output_width / svg_w
        @y_scale = @output_height / svg_h
      end

      # Draws the SVG onto the PDF page.
      def draw : Nil
        # Save graphics state
        page.save_graphics_state

        # Point SVG (u, v) → page (x + (u - min_x)·sx, y - (v - min_y)·sy) :
        # `at` est le coin haut-gauche du dessin.
        min_x, min_y = parser.viewbox.try { |vb| {vb[0], vb[1]} } || {0.0, 0.0}
        page.transform(@x_scale, 0, 0, -@y_scale, @x - min_x * @x_scale, @y + min_y * @y_scale)

        parser.elements.each do |element|
          render_element(element)
        end

        page.restore_graphics_state
      end

      private def render_element(node : XML::Node) : Nil
        return unless node.element?

        tag = node.name.downcase

        transform_val = node["transform"]?

        case tag
        when "defs", "title", "desc", "metadata", "style", "marker"
          # Skip non-renderable elements
          return
        end

        # Element-level transforms must apply to every renderable branch
        # below (not just <g>), otherwise a transform on e.g. a bare
        # <rect> is silently dropped.
        page.save_graphics_state
        if transform_val
          matrix = Transform.parse(transform_val)
          page.transform(*matrix) unless matrix == Transform::IDENTITY
        end

        case tag
        when "g"
          apply_styles(node)
          node.children.each { |child| render_element(child) }
        when "rect"
          draw_rect(node)
        when "circle"
          draw_circle(node)
        when "ellipse"
          draw_ellipse(node)
        when "line"
          draw_line(node)
        when "polyline"
          draw_polyline(node)
        when "polygon"
          draw_polygon(node)
        when "path"
          draw_path(node)
        when "text"
          draw_text(node)
        when "svg"
          # Nested SVG - process children
          node.children.each { |child| render_element(child) }
        else
          # Try to render children for unknown container elements
          node.children.each { |child| render_element(child) }
        end

        page.restore_graphics_state
      end

      private def draw_rect(node : XML::Node) : Nil
        rx = parse_coord(node["x"]?) || 0.0
        ry_svg = parse_coord(node["y"]?) || 0.0
        w = parse_coord(node["width"]?) || 0.0
        h = parse_coord(node["height"]?) || 0.0
        return if w <= 0 || h <= 0

        page.save_graphics_state
        apply_styles(node)
        # Axe y retourné : le rectangle s'étend vers le bas depuis
        # (x, y), son coin haut-gauche, comme en SVG.
        page.rectangle(rx, ry_svg, w, h)
        apply_fill_and_stroke(node)
        page.restore_graphics_state
      end

      private def draw_circle(node : XML::Node) : Nil
        cx = parse_coord(node["cx"]?) || 0.0
        cy = parse_coord(node["cy"]?) || 0.0
        r = parse_coord(node["r"]?) || 0.0
        return if r <= 0

        page.save_graphics_state
        apply_styles(node)
        draw_ellipse_path(cx, cy, r, r)
        apply_fill_and_stroke(node)
        page.restore_graphics_state
      end

      private def draw_ellipse(node : XML::Node) : Nil
        cx = parse_coord(node["cx"]?) || 0.0
        cy = parse_coord(node["cy"]?) || 0.0
        rx = parse_coord(node["rx"]?) || 0.0
        ry = parse_coord(node["ry"]?) || 0.0
        return if rx <= 0 || ry <= 0

        page.save_graphics_state
        apply_styles(node)
        draw_ellipse_path(cx, cy, rx, ry)
        apply_fill_and_stroke(node)
        page.restore_graphics_state
      end

      # Ellipse approchée par 4 courbes de Bézier cubiques.
      private def draw_ellipse_path(cx : Float64, cy : Float64, rx : Float64, ry : Float64) : Nil
        kappa = 0.5522847498 # 4 * (sqrt(2) - 1) / 3
        ox = rx * kappa
        oy = ry * kappa

        page.move_to(cx - rx, cy)
        page.curve_to(cx - rx, cy + oy, cx - ox, cy + ry, cx, cy + ry)
        page.curve_to(cx + ox, cy + ry, cx + rx, cy + oy, cx + rx, cy)
        page.curve_to(cx + rx, cy - oy, cx + ox, cy - ry, cx, cy - ry)
        page.curve_to(cx - ox, cy - ry, cx - rx, cy - oy, cx - rx, cy)
      end

      private def draw_line(node : XML::Node) : Nil
        x1 = parse_coord(node["x1"]?) || 0.0
        y1 = parse_coord(node["y1"]?) || 0.0
        x2 = parse_coord(node["x2"]?) || 0.0
        y2 = parse_coord(node["y2"]?) || 0.0

        page.save_graphics_state
        apply_styles(node)
        page.move_to(x1, y1)
        page.line_to(x2, y2)
        page.stroke
        page.restore_graphics_state

        draw_markers(node, [PathCommand.new('M', [x1, y1]), PathCommand.new('L', [x2, y2])])
      end

      private def draw_polyline(node : XML::Node) : Nil
        points = parse_points(node["points"]?)
        return if points.size < 2

        page.save_graphics_state
        apply_styles(node)

        page.move_to(*points[0])
        points[1..].each { |pt| page.line_to(*pt) }

        apply_fill_and_stroke(node)
        page.restore_graphics_state

        draw_markers(node, points_commands(points))
      end

      private def draw_polygon(node : XML::Node) : Nil
        points = parse_points(node["points"]?)
        return if points.size < 3

        page.save_graphics_state
        apply_styles(node)

        page.move_to(*points[0])
        points[1..].each { |pt| page.line_to(*pt) }
        # Close the path
        page.line_to(*points[0])

        apply_fill_and_stroke(node)
        page.restore_graphics_state

        draw_markers(node, points_commands(points) << PathCommand.new('Z'))
      end

      private def draw_path(node : XML::Node) : Nil
        d = node["d"]?
        return unless d

        commands = PathParser.parse(d)
        return if commands.empty?

        page.save_graphics_state
        apply_styles(node)

        commands.each do |cmd|
          case cmd.type
          when 'M'
            page.move_to(cmd.args[0], cmd.args[1])
          when 'L'
            page.line_to(cmd.args[0], cmd.args[1])
          when 'C'
            a = cmd.args
            page.curve_to(a[0], a[1], a[2], a[3], a[4], a[5])
          when 'Z'
            # Close the subpath only. The fill/stroke decision is made
            # below in `apply_fill_and_stroke`; calling `close_stroke`
            # here would consume the path and leave nothing for the
            # fill operator, which is why SVGs with closed shapes
            # (e.g. country flags) used to render as a thin outline
            # instead of filled colour bands.
            page.close_path
          end
        end

        apply_fill_and_stroke(node)
        page.restore_graphics_state

        draw_markers(node, commands)
      end

      private def points_commands(points : Array(Tuple(Float64, Float64))) : Array(PathCommand)
        points.map_with_index do |(x, y), i|
          PathCommand.new(i == 0 ? 'M' : 'L', [x, y])
        end
      end

      # Dessine les `marker-start`, `marker-mid` et `marker-end` (ou le
      # raccourci `marker`, propriétés héritées) aux sommets du tracé,
      # par-dessus l'élément et dans son repère.
      private def draw_markers(node : XML::Node, commands : Array(PathCommand)) : Nil
        return if parser.markers.empty?
        all = marker_ref(inherited_style(node, "marker"))
        start = marker_ref(inherited_style(node, "marker-start")) || all
        mid = marker_ref(inherited_style(node, "marker-mid")) || all
        finish = marker_ref(inherited_style(node, "marker-end")) || all
        return unless start || mid || finish

        vertices = MarkerGeometry.vertices(commands)
        return if vertices.empty?
        stroke_width = parse_coord(inherited_style(node, "stroke-width")) || 1.0

        draw_marker(start, vertices.first, stroke_width, start: true) if start
        if mid && vertices.size > 2
          vertices[1...-1].each { |vertex| draw_marker(mid, vertex, stroke_width) }
        end
        draw_marker(finish, vertices.last, stroke_width) if finish
      end

      # `<marker>` désigné par `url(#id)`, ou nil.
      private def marker_ref(value : String?) : XML::Node?
        return nil unless value
        id = value[/\Aurl\(\s*['"]?#([^'")\s]+)['"]?\s*\)\z/, 1]?
        id ? parser.markers[id]? : nil
      end

      # Ids des marqueurs en cours de dessin : un marqueur qui se
      # référence lui-même n'est pas redessiné.
      @marker_stack = [] of UInt64

      # Place le repère du marqueur au sommet : rotation selon `orient`,
      # échelle `markerUnits`, viewport `markerWidth` × `markerHeight`
      # (défaut 3) où le `viewBox` est ajusté, point `refX`/`refY` au
      # sommet ; le viewport découpe le dessin sauf `overflow: visible`.
      private def draw_marker(marker : XML::Node, vertex : MarkerGeometry::Vertex, stroke_width : Float64, start : Bool = false) : Nil
        key = marker.to_unsafe.address
        return if @marker_stack.includes?(key)

        width = parse_coord(marker["markerWidth"]?) || 3.0
        height = parse_coord(marker["markerHeight"]?) || 3.0
        return if width <= 0 || height <= 0

        sx, sy, tx, ty = marker_viewbox_transform(marker, width, height)
        ref_x = (parse_coord(marker["refX"]?) || 0.0) * sx + tx
        ref_y = (parse_coord(marker["refY"]?) || 0.0) * sy + ty
        scale = marker["markerUnits"]? == "userSpaceOnUse" ? 1.0 : stroke_width

        @marker_stack << key
        begin
          page.save_graphics_state
          page.translate(vertex.x, vertex.y)
          angle = marker_angle(marker["orient"]?, vertex, start)
          page.rotate(angle) unless angle.zero?
          page.scale(scale) unless scale == 1.0
          page.translate(-ref_x, -ref_y)
          unless {"visible", "auto"}.includes?(get_style(marker, "overflow"))
            page.rectangle(0, 0, width, height)
            page.clip!
          end
          page.transform(sx, 0, 0, sy, tx, ty) unless {sx, sy, tx, ty} == {1.0, 1.0, 0.0, 0.0}

          # Le contenu hérite du <marker>, pas de l'élément qui le porte.
          page.fill_color(0, 0, 0)
          page.stroke_color(0, 0, 0)
          page.line_width(1)
          page.line_join(:miter)
          page.line_cap(:butt)
          apply_styles(marker)
          marker.children.each { |child| render_element(child) }
          page.restore_graphics_state
        ensure
          @marker_stack.pop
        end
      end

      # Échelles et translation du `viewBox` vers le viewport
      # (`preserveAspectRatio`, défaut `xMidYMid meet`) :
      # point du viewBox (u, v) → (u·sx + tx, v·sy + ty).
      private def marker_viewbox_transform(marker : XML::Node, width : Float64, height : Float64) : Tuple(Float64, Float64, Float64, Float64)
        vb = marker["viewBox"]?.try(&.strip.split(/[\s,]+/).compact_map(&.to_f?))
        return {1.0, 1.0, 0.0, 0.0} unless vb && vb.size == 4 && vb[2] > 0 && vb[3] > 0
        min_x, min_y, vb_w, vb_h = vb[0], vb[1], vb[2], vb[3]
        sx = width / vb_w
        sy = height / vb_h
        par = (marker["preserveAspectRatio"]? || "xMidYMid meet").split
        align = par[0]? || "xMidYMid"
        unless align == "none"
          s = par[1]? == "slice" ? Math.max(sx, sy) : Math.min(sx, sy)
          sx = sy = s
        end
        tx = -min_x * sx
        ty = -min_y * sy
        tx += (width - vb_w * sx) * align_factor(align, 'x')
        ty += (height - vb_h * sy) * align_factor(align, 'y')
        {sx, sy, tx, ty}
      end

      # Part de l'espace libre placée avant le contenu : 0 (`Min`),
      # 0.5 (`Mid`) ou 1 (`Max`), pour l'axe `axis` de `align`.
      private def align_factor(align : String, axis : Char) : Float64
        return 0.0 if align == "none"
        part = axis == 'x' ? align[1, 3]? : align[5, 3]?
        case part
        when "Min" then 0.0
        when "Max" then 1.0
        else            0.5
        end
      end

      # Angle (degrés) du marqueur : `auto`, `auto-start-reverse` ou un
      # angle fixe (`45`, `45deg`, `0.5rad`, `50grad`, `0.25turn`).
      private def marker_angle(orient : String?, vertex : MarkerGeometry::Vertex, start : Bool) : Float64
        case orient = orient.try(&.strip) || "0"
        when "auto"
          vertex.angle
        when "auto-start-reverse"
          start ? vertex.angle + 180.0 : vertex.angle
        else
          m = orient.match(/\A([-+]?[\d.]+(?:e[-+]?\d+)?)(deg|rad|grad|turn)?\z/i)
          return 0.0 unless m && (value = m[1].to_f?)
          case m[2]?.try(&.downcase)
          when "rad"  then value * 180.0 / Math::PI
          when "grad" then value * 0.9
          when "turn" then value * 360.0
          else             value
          end
        end
      end

      private def draw_text(node : XML::Node) : Nil
        tx = parse_coord(node["x"]?) || 0.0
        ty = parse_coord(node["y"]?) || 0.0
        # SVG collapses runs of white space (xml:space="default").
        content = node.content.strip.gsub(/\s+/, " ")
        return if content.empty?

        # font-size, font-weight and text-anchor are inherited
        # properties : they are often set once on the root <svg> or a <g>.
        font_size = parse_coord(inherited_style(node, "font-size")) || 12.0
        bold = bold_weight?(inherited_style(node, "font-weight"))

        page.save_graphics_state
        apply_styles(node)
        width = select_text_font(bold, font_size, content)
        shift = case inherited_style(node, "text-anchor")
                when "middle" then width / 2
                when "end"    then width
                else               0.0
                end
        # Contre-retournement local : dans le repère SVG (y vers le
        # bas), le texte serait dessiné à l'envers.
        page.transform(1, 0, 0, -1, tx, ty)
        paint_text(node, content, -shift, 0.0)
        page.restore_graphics_state
      end

      # Peint le texte selon `fill`, `stroke` et `paint-order`. Le halo
      # usuel des plans (`text { stroke: #fff; stroke-width: 3px;
      # paint-order: stroke }`) demande le contour AVANT le remplissage :
      # deux passes (mode de rendu 1 puis 0), sinon le contour blanc
      # mangerait les lettres.
      private def paint_text(node : XML::Node, content : String, x : Float64, y : Float64) : Nil
        fill = get_style(node, "fill")
        stroke = get_style(node, "stroke")
        has_fill = fill != "none" # noir par défaut
        has_stroke = !stroke.nil? && stroke != "none" && !Color.parse(stroke).nil?

        if !has_stroke
          page.text(content, at: {x, y}) if has_fill
        elsif !has_fill
          page.text_rendering_mode(1)
          page.text(content, at: {x, y})
        elsif stroke_before_fill?(node)
          page.text_rendering_mode(1)
          page.text(content, at: {x, y})
          page.text_rendering_mode(0)
          page.text(content, at: {x, y})
        else
          page.text_rendering_mode(2)
          page.text(content, at: {x, y})
        end
      end

      # `paint-order` (hérité) : `normal`, ou une liste de `fill`,
      # `stroke`, `markers` complétée dans l'ordre par défaut.
      private def stroke_before_fill?(node : XML::Node) : Bool
        order = inherited_style(node, "paint-order").try(&.split) || [] of String
        stroke = order.index("stroke")
        return false unless stroke
        fill = order.index("fill")
        fill.nil? || stroke < fill
      end

      # Sets the font used for a `<text>` and returns the width of
      # `content` in that font, needed to honour `text-anchor`.
      private def select_text_font(bold : Bool, size : Float64, content : String) : Float64
        ttf = bold ? (@bold_font || @font) : @font
        if ttf
          page.font(ttf, size: size)
          ttf.string_width(content, size)
        else
          name = bold ? "Helvetica-Bold" : "Helvetica"
          page.font(name, size: size)
          page.document.font(name).string_width(content, size)
        end
      end

      private def bold_weight?(value : String?) : Bool
        return false unless value
        return true if value == "bold" || value == "bolder"
        (value.to_i? || 400) >= 600
      end

      private def apply_styles(node : XML::Node) : Nil
        # Fill color
        fill = get_style(node, "fill")
        if fill && fill != "none"
          if rgb = Color.parse(fill)
            page.fill_color(rgb[0], rgb[1], rgb[2])
          end
        end

        # Stroke color
        stroke_val = get_style(node, "stroke")
        if stroke_val && stroke_val != "none"
          if rgb = Color.parse(stroke_val)
            page.stroke_color(rgb[0], rgb[1], rgb[2])
          end
        end

        # Stroke width
        sw = get_style(node, "stroke-width")
        if sw
          if w = parse_coord(sw)
            page.line_width(w)
          end
        end

        case get_style(node, "stroke-linejoin")
        when "round" then page.line_join(:round)
        when "bevel" then page.line_join(:bevel)
        when "miter" then page.line_join(:miter)
        end

        case get_style(node, "stroke-linecap")
        when "round"  then page.line_cap(:round)
        when "square" then page.line_cap(:square)
        when "butt"   then page.line_cap(:butt)
        end

        apply_opacity(node)
      end

      # `opacity` applies to the whole element, `fill-opacity` and
      # `stroke-opacity` to one paint : the effective alpha is their
      # product. Set on a `<g>`, the graphics state carries it to the
      # children.
      private def apply_opacity(node : XML::Node) : Nil
        opacity = parse_opacity(get_style(node, "opacity"))
        fill = parse_opacity(get_style(node, "fill-opacity"))
        stroke = parse_opacity(get_style(node, "stroke-opacity"))
        return unless opacity || fill || stroke

        base = opacity || 1.0
        page.set_opacity(
          fill: (opacity || fill) ? base * (fill || 1.0) : nil,
          stroke: (opacity || stroke) ? base * (stroke || 1.0) : nil,
        )
      end

      # Parses an opacity value : a number (`0.4`) or a percentage (`40%`).
      private def parse_opacity(value : String?) : Float64?
        return nil unless value
        v = value.strip
        number = v.ends_with?('%') ? v.rchop.to_f?.try(&./(100.0)) : v.to_f?
        number.try(&.clamp(0.0, 1.0))
      end

      private def apply_fill_and_stroke(node : XML::Node) : Nil
        fill = get_style(node, "fill")
        stroke_val = get_style(node, "stroke")

        has_fill = fill.nil? || (fill != "none") # default fill is black
        has_stroke = stroke_val && stroke_val != "none"

        if has_fill && has_stroke
          page.fill_stroke
        elsif has_fill
          page.fill
        elsif has_stroke
          page.stroke
        else
          page.end_path
        end
      end

      # Valeur d'une propriété pour `node`, selon la cascade SVG :
      # attribut de présentation < règles `<style>` (par spécificité,
      # puis ordre du source) < attribut `style=""`, les déclarations
      # `!important` passant devant.
      private def get_style(node : XML::Node, property : String) : String?
        inline = node["style"]?.try do |style|
          Stylesheet.parse_declarations(style).reverse.find { |d| d.property == property }
        end
        css = parser.stylesheet.lookup(node, property)
        if css && css.important && !inline.try(&.important)
          return css.value
        end
        return inline.value if inline
        return css.value if css

        node[property]?
      end

      # Like `get_style`, but climbs the ancestors (up to the root
      # `<svg>`) for inherited properties such as `font-size`.
      private def inherited_style(node : XML::Node, property : String) : String?
        current = node
        while current && current.element?
          if value = get_style(current, property)
            return value unless value == "inherit"
          end
          current = current.parent
        end
        nil
      end

      private def parse_coord(value : String?) : Float64?
        Parser.parse_length(value)
      end

      private def parse_points(value : String?) : Array(Tuple(Float64, Float64))
        return [] of Tuple(Float64, Float64) unless value
        numbers = value.strip.split(/[\s,]+/).compact_map(&.to_f?)
        points = [] of Tuple(Float64, Float64)
        i = 0
        while i + 1 < numbers.size
          points << {numbers[i], numbers[i + 1]}
          i += 2
        end
        points
      end
    end
  end
end
