require "../../spec_helper"
require "../../support/svg_geometry"

private def close_to(actual : Tuple, expected : Tuple)
  actual.size.should eq(expected.size)
  actual.each_with_index { |v, i| v.should be_close(expected[i], 0.001) }
end

# Triangle de 10 × 10 pointant vers +x, pointe (10, 5) sur le sommet.
private def arrow_svg(body : String, marker_attrs = %(markerUnits="userSpaceOnUse" markerWidth="10" markerHeight="10"), orient = "auto")
  %(<svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
    <defs><marker id="a" viewBox="0 0 10 10" refX="10" refY="5" #{marker_attrs} orient="#{orient}">
      <path d="M0,0 L10,5 L0,10 z" fill="red"/></marker></defs>
    #{body}</svg>)
end

# Les trois sommets (page) du dernier triangle de marqueur dessiné.
private def arrow_points(result : SvgGeometry::Result, index = -1)
  result.points[(index * 3)..(index * 3 + 2)]
end

describe "SVG markers" do
  # SVG de 100 × 100 posé en (0, 100) : point SVG (x, y) → page (x, 100 - y).
  render = ->(svg : String) { SvgGeometry.render(svg, at: {0, 100}) }

  it "draws marker-end at the last vertex, pointing along the line" do
    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-end="url(#a)"/>)))
    tri = arrow_points(r)
    close_to(tri[0], {80.0, 55.0})
    close_to(tri[1], {90.0, 50.0})
    close_to(tri[2], {80.0, 45.0})
  end

  it "draws marker-start at the first vertex, reversed with auto-start-reverse" do
    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-start="url(#a)"/>)))
    close_to(arrow_points(r)[1], {10.0, 50.0})
    close_to(arrow_points(r)[0], {0.0, 55.0})

    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-start="url(#a)"/>),
      orient: "auto-start-reverse"))
    close_to(arrow_points(r)[1], {10.0, 50.0})
    close_to(arrow_points(r)[0], {20.0, 45.0})
  end

  it "orients auto along a diagonal" do
    r = render.call(arrow_svg(%(<line x1="0" y1="0" x2="50" y2="50" stroke="black" marker-end="url(#a)"/>)))
    tri = arrow_points(r)
    close_to(tri[1], {50.0, 50.0})
    # (0, 0) du marqueur, soit (-10, -5) de la pointe, tourné de 45°.
    h = Math.sqrt(0.5)
    close_to(tri[0], {50.0 + (-10 + 5) * h, 100.0 - (50.0 + (-10 - 5) * h)})
  end

  it "uses a fixed orient angle" do
    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-end="url(#a)"/>),
      orient: "90"))
    # Pointe vers le bas (y SVG croissant).
    close_to(arrow_points(r)[0], {95.0, 60.0})
  end

  it "scales with stroke-width by default (markerUnits strokeWidth)" do
    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" stroke-width="2" marker-end="url(#a)"/>),
      marker_attrs: %(markerWidth="5" markerHeight="5")))
    tri = arrow_points(r)
    close_to(tri[0], {80.0, 55.0})
    close_to(tri[1], {90.0, 50.0})
  end

  it "defaults markerWidth and markerHeight to 3" do
    r = render.call(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-end="url(#a)"/>),
      marker_attrs: ""))
    close_to(arrow_points(r)[0], {87.0, 51.5})
  end

  it "follows the end tangent of a path curve and the marker-mid bisector" do
    r = render.call(arrow_svg(%(<path d="M10,50 C30,10 70,10 90,50" fill="none" stroke="black" marker-end="url(#a)"/>)))
    tri = arrow_points(r)
    close_to(tri[1], {90.0, 50.0})
    # Tangente d'arrivée : (90, 50) - (70, 10) = (20, 40).
    len = Math.sqrt(20.0 ** 2 + 40.0 ** 2)
    ux, uy = 20.0 / len, 40.0 / len
    base = {90.0 - 10 * ux + 5 * uy, 50.0 - 10 * uy - 5 * ux}
    close_to(tri[0], {base[0], 100.0 - base[1]})

    r = render.call(arrow_svg(%(<polyline points="10,90 50,50 90,90" fill="none" stroke="black" marker-mid="url(#a)"/>)))
    # Bissectrice de (1, -1) et (1, 1) : horizontale.
    close_to(arrow_points(r)[0], {40.0, 55.0})
  end

  it "clips to the marker viewport unless overflow is visible" do
    clipped = ""
    visible = ""
    {false, true}.each do |overflow|
      PDF::Document.new.page do |page|
        attrs = %(markerUnits="userSpaceOnUse" markerWidth="10" markerHeight="10") + (overflow ? %( overflow="visible") : "")
        page.svg(arrow_svg(%(<line x1="10" y1="50" x2="90" y2="50" stroke="black" marker-end="url(#a)"/>), attrs), at: {0, 100})
        overflow ? (visible = page.content_string) : (clipped = page.content_string)
      end
    end
    clipped.should contain("W\nn")
    visible.should_not contain("W\nn")
  end

  it "resolves markers from CSS and the marker shorthand, and never draws <marker> in place" do
    r = render.call(arrow_svg(%(<style>.f { marker: url(#a) }</style>
      <polygon class="f" points="10,10 90,10 90,90" fill="none" stroke="black"/>)))
    # 3 points du polygone + 1 fermeture, puis 4 marqueurs (départ, 2 intermédiaires, fin).
    r.points.size.should eq(4 + 4 * 3)
    r = render.call(arrow_svg(""))
    r.points.should be_empty
  end
end

describe PDF::SVG::MarkerGeometry do
  it "computes vertices and directions of a path" do
    commands = PDF::SVG::PathParser.parse("M0,0 L10,0 L10,10 Z")
    v = PDF::SVG::MarkerGeometry.vertices(commands)
    v.map { |x| {x.x, x.y} }.should eq([{0.0, 0.0}, {10.0, 0.0}, {10.0, 10.0}, {0.0, 0.0}])
    v[0].angle.should eq(0.0)
    v[1].angle.should be_close(45.0, 1e-9)
    v[3].angle.should be_close(-135.0, 1e-9)
  end
end
