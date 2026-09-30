require "../spec_helper"

describe PDF::ColorSpaces::ICCBased do
  describe ".srgb_v4" do
    it "loads the bundled sRGB v4 profile and reports 3 components" do
      icc = PDF::ColorSpaces::ICCBased.srgb_v4
      icc.num_components.should eq(3)
      icc.data.size.should be > 1000 # ~60 KB profile
    end
  end

  describe ".fogra39" do
    it "loads the bundled FOGRA39 profile and reports 4 components (CMYK)" do
      icc = PDF::ColorSpaces::ICCBased.fogra39
      icc.num_components.should eq(4)
      icc.data.size.should be > 100_000 # ~1.7 MB profile
    end
  end

  describe "bundled profiles" do
    profiles = {
      "srgb_v4"      => {PDF::ColorSpaces::ICCBased::SRGB_V4_PATH, -> { PDF::ColorSpaces::ICCBased.srgb_v4 }},
      "srgb_display" => {PDF::ColorSpaces::ICCBased::SRGB_DISPLAY_PATH, -> { PDF::ColorSpaces::ICCBased.srgb_display }},
      "fogra39"      => {PDF::ColorSpaces::ICCBased::FOGRA39_PATH, -> { PDF::ColorSpaces::ICCBased.fogra39 }},
    }

    profiles.each do |name, (path, factory)|
      it "#{name} returns the bytes of #{File.basename(path)}" do
        icc = factory.call
        icc.data.should eq(File.read(path).to_slice)
      end
    end

    # An installed program (FreeBSD package, server) no longer has the
    # shard's source tree: the profiles must not be looked up there.
    it "work without the data/icc directory" do
      icc_dir = File.dirname(PDF::ColorSpaces::ICCBased::SRGB_DISPLAY_PATH)
      hidden = "#{icc_dir}.hidden-by-spec"
      expected = profiles.transform_values { |(path, _)| File.read(path).to_slice }
      File.rename(icc_dir, hidden)
      begin
        Dir.exists?(icc_dir).should be_false
        profiles.each do |name, (_, factory)|
          factory.call.data.should eq(expected[name])
        end
        pdf = PDF::Document.new
        pdf.page { |_| }
        pdf.output_intent = PDF::OutputIntent.srgb
        pdf.to_slice.map(&.chr).join.should contain("/DestOutputProfile")
      ensure
        File.rename(hidden, icc_dir)
      end
    end
  end

  describe ".new" do
    it "rejects byte arrays smaller than 128 bytes (ICC header size)" do
      expect_raises(ArgumentError, /too small/) do
        PDF::ColorSpaces::ICCBased.new(Bytes.new(50))
      end
    end

    it "rejects an unknown colour-space signature" do
      # 128-byte header with bytes 16-19 = "XXXX"
      junk = Bytes.new(128) { 0_u8 }
      junk[16] = 'X'.ord.to_u8
      junk[17] = 'X'.ord.to_u8
      junk[18] = 'X'.ord.to_u8
      junk[19] = 'X'.ord.to_u8
      expect_raises(ArgumentError, /Unknown ICC colour-space signature/) do
        PDF::ColorSpaces::ICCBased.new(junk)
      end
    end
  end

  describe "#to_stream" do
    it "produces a stream dict carrying /N = num_components" do
      stream = PDF::ColorSpaces::ICCBased.srgb_v4.to_stream
      stream["N"].to_pdf.should eq("3")
    end
  end
end

describe PDF::OutputIntent do
  describe ".srgb" do
    it "builds a /GTS_PDFA1 output intent with sRGB metadata" do
      oi = PDF::OutputIntent.srgb
      oi.subtype.should eq("GTS_PDFA1")
      oi.output_condition_identifier.should eq("sRGB")
      oi.dest_output_profile.num_components.should eq(3)
    end
  end

  describe ".fogra39" do
    it "builds a /GTS_PDFA1 output intent with FOGRA39 metadata (CMYK)" do
      oi = PDF::OutputIntent.fogra39
      oi.subtype.should eq("GTS_PDFA1")
      oi.output_condition_identifier.should eq("FOGRA39")
      oi.dest_output_profile.num_components.should eq(4)
    end
  end

  describe ".new with custom subtype" do
    it "accepts :gts_pdfx" do
      oi = PDF::OutputIntent.new(
        subtype: :gts_pdfx,
        output_condition_identifier: "X",
        dest_output_profile: PDF::ColorSpaces::ICCBased.srgb_v4,
      )
      oi.subtype.should eq("GTS_PDFX")
    end

    it "rejects an unknown subtype symbol" do
      expect_raises(ArgumentError, /Unknown OutputIntent subtype/) do
        PDF::OutputIntent.new(
          subtype: :unknown_subtype,
          output_condition_identifier: "X",
          dest_output_profile: PDF::ColorSpaces::ICCBased.srgb_v4,
        )
      end
    end
  end
end

describe "Document#output_intent (integration)" do
  it "emits /OutputIntents in the catalog when an intent is set" do
    pdf = PDF::Document.new
    pdf.page { |_| }
    pdf.output_intent = PDF::OutputIntent.srgb

    bytes = pdf.to_slice
    out = bytes.map(&.chr).join

    out.should contain("/OutputIntents")
    out.should contain("/Type /OutputIntent")
    out.should contain("/S /GTS_PDFA1")
    out.should contain("/OutputConditionIdentifier (sRGB)")
    out.should contain("/DestOutputProfile")
  end

  it "does not emit /OutputIntents when no intent is set" do
    pdf = PDF::Document.new
    pdf.page { |_| }
    bytes = pdf.to_slice
    out = bytes.map(&.chr).join
    out.should_not contain("/OutputIntents")
  end

  it "embeds an ICCBased stream with /N matching the profile" do
    pdf = PDF::Document.new
    pdf.page { |_| }
    pdf.output_intent = PDF::OutputIntent.fogra39

    bytes = pdf.to_slice
    out = bytes.map(&.chr).join
    # FOGRA39 is CMYK → /N 4
    out.should contain("/N 4")
  end
end
