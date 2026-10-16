require "../spec_helper"

describe PDF::Destination do
  page_ref = PDF::Objects::Reference.new(5)

  describe ".xyz" do
    it "creates XYZ destination" do
      dest = PDF::Destination.xyz(page_ref, left: 0, top: 842, zoom: 1.0)
      dest.to_pdf.should eq("[5 0 R /XYZ 0 842 1]")
    end

    it "handles nil parameters" do
      dest = PDF::Destination.xyz(page_ref)
      dest.to_pdf.should eq("[5 0 R /XYZ null null null]")
    end
  end

  describe ".fit" do
    it "creates Fit destination" do
      dest = PDF::Destination.fit(page_ref)
      dest.to_pdf.should eq("[5 0 R /Fit]")
    end
  end

  describe ".fit_horizontally" do
    it "creates FitH destination" do
      dest = PDF::Destination.fit_horizontally(page_ref, top: 842)
      dest.to_pdf.should eq("[5 0 R /FitH 842]")
    end
  end

  describe ".fit_vertically" do
    it "creates FitV destination" do
      dest = PDF::Destination.fit_vertically(page_ref, left: 0)
      dest.to_pdf.should eq("[5 0 R /FitV 0]")
    end
  end

  describe ".fit_rect" do
    it "creates FitR destination" do
      dest = PDF::Destination.fit_rect(page_ref, left: 0, bottom: 0, right: 595, top: 842)
      dest.to_pdf.should eq("[5 0 R /FitR 0 0 595 842]")
    end
  end

  describe ".fit_bounds" do
    it "creates FitB destination" do
      dest = PDF::Destination.fit_bounds(page_ref)
      dest.to_pdf.should eq("[5 0 R /FitB]")
    end
  end

  describe ".fit_bounds_horizontally" do
    it "creates FitBH destination" do
      dest = PDF::Destination.fit_bounds_horizontally(page_ref, top: 842)
      dest.to_pdf.should eq("[5 0 R /FitBH 842]")
    end
  end

  describe ".fit_bounds_vertically" do
    it "creates FitBV destination" do
      dest = PDF::Destination.fit_bounds_vertically(page_ref, left: 0)
      dest.to_pdf.should eq("[5 0 R /FitBV 0]")
    end
  end
end

describe PDF::Document do
  describe "#add_dest" do
    it "adds named destinations to the catalog" do
      pdf = PDF::Document.new
      page = pdf.page do |p|
        p.font "Helvetica", size: 12
        p.text "Chapter 1", at: {72, 720}
      end

      page_ref = page.page_reference
      dest = PDF::Destination.fit(page_ref)
      pdf.add_dest("chapter-1", dest)

      output = pdf.to_slice
      content = String.new(output)
      content.should contain("/Dests")
      content.should contain("chapter-1")
    end
  end
end
