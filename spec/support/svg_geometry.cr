# Interprète le flux de contenu d'une page (q/Q, cm, w, m, l, c, re,
# Tf, Td) pour obtenir la géométrie réellement produite en coordonnées
# de page, quelle que soit la façon dont le renderer compose ses
# matrices. Sert aux specs de non-régression des positions SVG.
module SvgGeometry
  alias Point = Tuple(Float64, Float64)

  record Text, origin : Point, size : Float64, upright : Bool, text : String

  class Result
    getter points = [] of Point
    getter rects = [] of Tuple(Float64, Float64, Float64, Float64)
    getter texts = [] of Text
    getter line_widths = [] of Float64
  end

  def self.analyse(content : String) : Result
    result = Result.new
    ctm = PDF::SVG::Transform::IDENTITY
    stack = [] of PDF::SVG::Transform::Matrix
    size = 0.0
    td = {0.0, 0.0}
    content.each_line do |line|
      tokens = line.split
      next if tokens.empty?
      nums = tokens[0...-1].compact_map(&.to_f?)
      case tokens.last
      when "q"  then stack << ctm
      when "Q"  then ctm = stack.pop
      when "cm" then ctm = PDF::SVG::Transform.multiply(ctm, {nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]})
      when "w"  then result.line_widths << nums[0] * Math.sqrt((ctm[0] * ctm[3] - ctm[1] * ctm[2]).abs)
      when "m", "l"
        result.points << PDF::SVG::Transform.apply(ctm, nums[0], nums[1])
      when "c"
        result.points << PDF::SVG::Transform.apply(ctm, nums[4], nums[5])
      when "re"
        x0, y0 = PDF::SVG::Transform.apply(ctm, nums[0], nums[1])
        x1, y1 = PDF::SVG::Transform.apply(ctm, nums[0] + nums[2], nums[1] + nums[3])
        result.rects << {Math.min(x0, x1), Math.min(y0, y1), Math.max(x0, x1), Math.max(y0, y1)}
      when "Tf" then size = tokens[-2].to_f
      when "Td" then td = {nums[0], nums[1]}
      when "Tj"
        # Taille effective : échelle verticale de la CTM ; à l'endroit
        # quand l'axe y du texte monte sur la page.
        origin = PDF::SVG::Transform.apply(ctm, td[0], td[1])
        scale = Math.sqrt(ctm[2] ** 2 + ctm[3] ** 2)
        text = line[/\((.*)\) Tj/, 1]? || ""
        result.texts << Text.new(origin, size * scale, ctm[3] > 0, text)
      end
    end
    result
  end

  def self.render(svg : String, at = {50, 700}, width : Float64? = nil, height : Float64? = nil) : Result
    result = Result.new
    PDF::Document.new.page do |page|
      page.svg(svg, at: at, width: width, height: height)
      result = analyse(page.content_string)
    end
    result
  end
end
