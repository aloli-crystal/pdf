module PDF
  class Page
    # Renders an SVG string onto the page at the specified position.
    #
    # `font` / `bold_font` are optional TrueType fonts for the SVG
    # `<text>` elements ; without them the standard Helvetica is used,
    # limited to WinAnsi glyphs.
    #
    # The page's current font is restored afterwards : drawing an SVG
    # never changes the font of the caller's next `text` call.
    #
    # ```
    # svg_data = File.read("image.svg")
    # page.svg(svg_data, at: {50, 700}, width: 200)
    # ```
    def svg(
      svg_data : String,
      *,
      at : Tuple(Number, Number) = {0, 0},
      width : Float64? = nil,
      height : Float64? = nil,
      font : Fonts::TrueTypeFont? = nil,
      bold_font : Fonts::TrueTypeFont? = nil,
    ) : SVG::Renderer
      # Reuse a cached parser when the same SVG string is rendered
      # multiple times on the same document (typical for repeated
      # country flags in a table). The cache is document-scoped.
      parser = document.svg_parser_for(svg_data)
      renderer = SVG::Renderer.new(
        self,
        parser,
        x: at[0].to_f,
        y: at[1].to_f,
        width: width,
        height: height,
        font: font,
        bold_font: bold_font,
      )
      saved_font = {@current_font, @current_font_size, @current_truetype_font}
      begin
        renderer.draw
      ensure
        @current_font, @current_font_size, @current_truetype_font = saved_font
      end
      renderer
    end
  end
end
