require "../spec_helper"

describe PDF::Outline do
  describe "#define" do
    it "creates a simple outline with items" do
      pdf = PDF::Document.new
      page1 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("Page 1", at: {72, 720}) }
      page2 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("Page 2", at: {72, 720}) }

      dest1 = PDF::Destination.fit(page1.page_reference)
      dest2 = PDF::Destination.fit(page2.page_reference)

      pdf.outline.define do |o|
        o.item("Introduction", dest: dest1)
        o.item("Conclusion", dest: dest2)
      end

      output = pdf.to_slice
      content = String.new(output)
      content.should contain("/Outlines")
      content.should contain("/Title")
      content.should contain("/Fit")
    end

    it "creates nested outline sections" do
      pdf = PDF::Document.new
      page1 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("P1", at: {72, 720}) }
      page2 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("P2", at: {72, 720}) }
      page3 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("P3", at: {72, 720}) }

      pdf.outline.define do |o|
        o.section("Chapter 1", dest: PDF::Destination.fit(page1.page_reference)) do
          o.item("Section 1.1", dest: PDF::Destination.fit(page1.page_reference))
          o.item("Section 1.2", dest: PDF::Destination.fit(page2.page_reference))
        end
        o.section("Chapter 2", dest: PDF::Destination.fit(page3.page_reference))
      end

      output = pdf.to_slice
      content = String.new(output)
      content.should contain("/Outlines")
      content.should contain("/First")
      content.should contain("/Last")
      content.should contain("/Parent")
    end

    it "supports closed sections" do
      pdf = PDF::Document.new
      page1 = pdf.page { |p| p.font("Helvetica", size: 12); p.text("P1", at: {72, 720}) }

      pdf.outline.define do |o|
        o.section("Collapsed", dest: PDF::Destination.fit(page1.page_reference), closed: true) do
          o.item("Hidden item", dest: PDF::Destination.fit(page1.page_reference))
        end
      end

      output = pdf.to_slice
      content = String.new(output)
      # Closed sections have negative count
      content.should contain("/Count -1")
    end
  end

  describe "without outline" do
    it "does not add outline to catalog" do
      pdf = PDF::Document.new
      pdf.page { |p| p.font("Helvetica", size: 12); p.text("No outline", at: {72, 720}) }

      output = pdf.to_slice
      content = String.new(output)
      content.should_not contain("/Outlines")
    end
  end
end

describe "Integration: annotations + destinations + outline" do
  it "creates a complete navigable PDF" do
    pdf = PDF::Document.new
    pdf.title = "Test Document"

    page1 = pdf.page(size: :a4) do |p|
      p.font("Helvetica-Bold", size: 24)
      p.text("Chapter 1: Introduction", at: {72, 750})
      p.font("Helvetica", size: 12)
      p.text("See chapter 2 for details.", at: {72, 700})
      p.link_dest(rect: {72, 690, 250, 710}, dest: "chapter-2")
    end

    page2 = pdf.page(size: :a4) do |p|
      p.font("Helvetica-Bold", size: 24)
      p.text("Chapter 2: Details", at: {72, 750})
      p.font("Helvetica", size: 12)
      p.text("Visit Crystal website", at: {72, 700})
      p.link_uri(rect: {72, 690, 250, 710}, uri: "https://crystal-lang.org")
    end

    # Named destinations
    pdf.add_dest("chapter-1", PDF::Destination.fit(page1.page_reference))
    pdf.add_dest("chapter-2", PDF::Destination.fit(page2.page_reference))

    # Outline (bookmarks)
    pdf.outline.define do |o|
      o.item("Chapter 1: Introduction", dest: PDF::Destination.fit(page1.page_reference))
      o.item("Chapter 2: Details", dest: PDF::Destination.fit(page2.page_reference))
    end

    output = pdf.to_slice
    content = String.new(output)

    # Verify all features present
    content.should contain("/Annots")
    content.should contain("/URI")
    content.should contain("crystal-lang.org")
    content.should contain("/Dests")
    content.should contain("chapter-1")
    content.should contain("chapter-2")
    content.should contain("/Outlines")
    content.should contain("/Title")

    # Verify it's a valid PDF
    content.should start_with("%PDF-")
    content.should contain("%%EOF")
  end
end
