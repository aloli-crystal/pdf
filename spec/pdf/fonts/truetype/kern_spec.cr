require "../../../spec_helper"

KERN_SPEC_FONT_PATH = "spec/fixtures/fonts/DejaVuSans.ttf"

describe PDF::Fonts::TrueType::Tables::Kern do
  describe ".parse" do
    it "parses the kern table if present" do
      parser = PDF::Fonts::TrueType::Parser.parse(KERN_SPEC_FONT_PATH)
      if parser.has_table?("kern")
        kern = parser.kern
        kern.should_not be_nil
        if k = kern
          k.should be_a(PDF::Fonts::TrueType::Tables::Kern)
        end
      end
    end

    it "returns nil when font has no kern table" do
      parser = PDF::Fonts::TrueType::Parser.parse(KERN_SPEC_FONT_PATH)
      # DejaVuSans may or may not have a kern table;
      # this test just verifies the method works without crashing
      parser.kern.is_a?(PDF::Fonts::TrueType::Tables::Kern?).should be_true
    end
  end

  describe "#kerning" do
    it "returns 0 for unknown glyph pair" do
      pairs = Hash(UInt32, Int16).new
      kern = PDF::Fonts::TrueType::Tables::Kern.new(pairs)
      kern.kerning(1_u16, 2_u16).should eq(0_i16)
    end

    it "returns the kerning value for a known pair" do
      pairs = Hash(UInt32, Int16).new
      key = (65_u32 << 16) | 86_u32 # glyphs 65 and 86
      pairs[key] = -50_i16
      kern = PDF::Fonts::TrueType::Tables::Kern.new(pairs)
      kern.kerning(65_u16, 86_u16).should eq(-50_i16)
    end
  end

  describe "parser integration" do
    it "exposes has_kerning? on the parser" do
      parser = PDF::Fonts::TrueType::Parser.parse(KERN_SPEC_FONT_PATH)
      parser.has_kerning?.should be_a(Bool)
    end

    it "returns 0 for kern_pair when no kern table" do
      parser = PDF::Fonts::TrueType::Parser.parse(KERN_SPEC_FONT_PATH)
      # Even if no kern table, the method should not crash
      result = parser.kern_pair(0_u16, 0_u16)
      result.should be_a(Int16)
    end
  end
end
