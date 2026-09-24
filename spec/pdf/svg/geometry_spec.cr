require "../../spec_helper"
require "../../support/svg_geometry"

private def close_to(actual : Tuple, expected : Tuple)
  actual.size.should eq(expected.size)
  actual.each_with_index { |v, i| v.should be_close(expected[i], 0.001) }
end

describe "SVG geometry (positions on the page)" do
  it "places a rect with its top-left corner at `at`" do
    r = SvgGeometry.render(%(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
      <rect x="10" y="10" width="80" height="40"/></svg>))
    close_to(r.rects.first, {60.0, 650.0, 140.0, 690.0})
  end

  it "scales to the requested width and height" do
    r = SvgGeometry.render(%(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
      <rect x="10" y="10" width="80" height="40" stroke="black" stroke-width="2"/></svg>),
      width: 400.0, height: 200.0)
    close_to(r.rects.first, {70.0, 600.0, 230.0, 680.0})
    r.line_widths.first.should be_close(4.0, 0.001)
  end

  it "maps the viewBox onto the output size" do
    r = SvgGeometry.render(%(<svg viewBox="0 0 100 50" xmlns="http://www.w3.org/2000/svg">
      <line x1="0" y1="0" x2="100" y2="50" stroke="black"/></svg>),
      width: 300.0, height: 150.0)
    close_to(r.points[0], {50.0, 700.0})
    close_to(r.points[1], {350.0, 550.0})
  end

  it "translates groups and shapes" do
    r = SvgGeometry.render(%(<svg width="200" height="200" xmlns="http://www.w3.org/2000/svg">
      <g transform="translate(50, 50)"><rect width="50" height="50"/></g>
      <rect transform="translate(20, 30)" width="10" height="10"/></svg>))
    close_to(r.rects[0], {100.0, 600.0, 150.0, 650.0})
    close_to(r.rects[1], {70.0, 660.0, 80.0, 670.0})
  end

  it "places circles, lines, polylines and paths" do
    r = SvgGeometry.render(%(<svg width="200" height="200" xmlns="http://www.w3.org/2000/svg">
      <circle cx="50" cy="50" r="40"/>
      <line x1="0" y1="0" x2="200" y2="100" stroke="black"/>
      <polyline points="0,40 40,40" stroke="black" fill="none"/>
      <path d="M 10 80 C 40 10, 65 10, 95 80" stroke="black" fill="none"/></svg>))
    close_to(r.points[0], {60.0, 650.0}) # début du cercle : (cx - r, cy)
    close_to(r.points[5], {50.0, 700.0})
    close_to(r.points[6], {250.0, 600.0})
    close_to(r.points[7], {50.0, 660.0})
    close_to(r.points[8], {90.0, 660.0})
    close_to(r.points[9], {60.0, 620.0})
    close_to(r.points[10], {145.0, 620.0})
  end

  it "places text upright at its baseline, scaled with the drawing" do
    r = SvgGeometry.render(%(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
      <text x="10" y="50" font-size="16">Hello</text></svg>),
      width: 400.0, height: 200.0)
    t = r.texts.first
    close_to(t.origin, {70.0, 600.0})
    t.size.should be_close(32.0, 0.001)
    t.upright.should be_true
  end

  it "shifts anchored text by its measured width" do
    width = PDF::Fonts::Type1.new("Helvetica").string_width("Test", 20.0)
    r = SvgGeometry.render(%(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
      <text x="100" y="50" font-size="20" text-anchor="middle">Test</text></svg>))
    close_to(r.texts.first.origin, {150.0 - width / 2, 650.0})
  end

  it "keeps a translated text in place" do
    r = SvgGeometry.render(%(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
      <g transform="translate(10, 20)"><text x="10" y="30">T</text></g></svg>))
    close_to(r.texts.first.origin, {70.0, 650.0})
    r.texts.first.upright.should be_true
  end

  it "rotates around a point wherever the drawing is placed" do
    r = SvgGeometry.render(%(<svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
      <line transform="rotate(90 50 50)" x1="50" y1="50" x2="60" y2="50" stroke="black"/></svg>),
      at: {100, 500})
    # (60, 50) tourne de 90° (sens horaire à l'écran) autour du centre → (50, 60).
    close_to(r.points[0], {150.0, 450.0})
    close_to(r.points[1], {150.0, 440.0})
  end

  it "honours a scale transform on a group at any position and output size" do
    r = SvgGeometry.render(%(<svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
      <g transform="translate(10 10) scale(2)"><rect width="5" height="5" stroke="black" stroke-width="1"/></g></svg>),
      at: {100, 500}, width: 200.0, height: 200.0)
    close_to(r.rects.first, {120.0, 460.0, 140.0, 480.0})
    r.line_widths.first.should be_close(4.0, 0.001)
  end

  it "shifts the drawing by the viewBox origin" do
    r = SvgGeometry.render(%(<svg viewBox="-10 20 100 50" xmlns="http://www.w3.org/2000/svg">
      <line x1="-10" y1="20" x2="90" y2="70" stroke="black"/></svg>),
      width: 200.0, height: 100.0)
    close_to(r.points[0], {50.0, 700.0})
    close_to(r.points[1], {250.0, 600.0})
  end
end
