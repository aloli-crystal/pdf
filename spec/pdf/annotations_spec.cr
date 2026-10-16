require "../spec_helper"

describe PDF::Annot do
  describe ".link_uri" do
    it "creates a URI link annotation" do
      annot = PDF::Annot.link_uri(rect: {72, 700, 200, 720}, uri: "https://crystal-lang.org")
      dict = annot.dict

      dict["Type"].to_pdf.should eq("/Annot")
      dict["Subtype"].to_pdf.should eq("/Link")
      dict["Rect"].to_pdf.should eq("[72 700 200 720]")

      action = dict["A"].as(PDF::Objects::Dictionary)
      action["S"].to_pdf.should eq("/URI")
      action["URI"].to_pdf.should eq("(https://crystal-lang.org)")
    end
  end

  describe ".link_dest" do
    it "creates a named destination link annotation" do
      annot = PDF::Annot.link_dest(rect: {72, 700, 200, 720}, dest: "chapter-1")
      dict = annot.dict

      dict["Subtype"].to_pdf.should eq("/Link")
      dict["Dest"].to_pdf.should eq("(chapter-1)")
    end
  end

  describe ".link_dest_array" do
    it "creates an annotation with explicit destination array" do
      page_ref = PDF::Objects::Reference.new(5)
      dest = PDF::Destination.fit(page_ref)
      annot = PDF::Annot.link_dest_array(rect: {72, 700, 200, 720}, dest: dest)

      dict = annot.dict
      dict["Dest"].to_pdf.should eq("[5 0 R /Fit]")
    end
  end

  describe ".text" do
    it "creates a text popup annotation" do
      annot = PDF::Annot.text(rect: {72, 700, 100, 720}, contents: "A comment")
      dict = annot.dict

      dict["Subtype"].to_pdf.should eq("/Text")
      dict["Type"].to_pdf.should eq("/Annot")
    end
  end
end

describe PDF::Page do
  describe "#add_annotation" do
    it "adds annotation to page and serializes in PDF" do
      pdf = PDF::Document.new
      page = pdf.page do |p|
        p.font "Helvetica", size: 12
        p.text "Click here", at: {72, 720}
        p.link_uri(rect: {72, 710, 150, 730}, uri: "https://example.com")
      end

      output = pdf.to_slice
      content = String.new(output)
      content.should contain("/Annots")
      content.should contain("/Link")
      content.should contain("/URI")
      content.should contain("https://example.com")
    end
  end

  describe "#link_dest" do
    it "adds internal link annotation" do
      pdf = PDF::Document.new
      page = pdf.page do |p|
        p.font "Helvetica", size: 12
        p.text "Go to chapter", at: {72, 720}
        p.link_dest(rect: {72, 710, 180, 730}, dest: "ch1")
      end

      output = pdf.to_slice
      content = String.new(output)
      content.should contain("/Link")
      content.should contain("ch1")
    end
  end
end
