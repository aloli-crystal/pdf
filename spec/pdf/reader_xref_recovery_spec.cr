require "../spec_helper"

# Spec de non-régression : certains PDFs écrits par des producteurs
# fautifs ont une table xref **décalée** — typiquement, la première
# sous-section déclare `first_obj=1` alors que la 1ère entrée est
# le marqueur « 0 free » (obj 0 libre, obligatoire ISO 32000-1
# § 7.5.4). Résultat : tous les offsets lus sont décalés d'une
# position, le Reader résout `/Root 5 0 R` sur un offset qui
# contient en réalité l'objet 4 (/Pages) → `KeyError: "Pages"`
# en silence, `page_count=0`, le document est ignoré au merge
# par `combine-pdf` sans erreur apparente.
#
# Cas vécu : un fichier `anamnese--irlandaise--amazing-grace--simple.pdf`
# d'un livret de messe 2026-11-11 a été discrètement avalé par
# `combine-pdf merge` (17 pages au lieu de 18, aucun warning).
# qpdf diagnostique proprement « expected 5 0 obj at offset …,
# Attempting to reconstruct cross-reference table ». Ce spec
# garantit que `PDF::Reader` sait désormais récupérer tout seul,
# comme Preview.app, Acrobat et qpdf le font.
# Forge un PDF minimal de ~500 octets avec exactement le même
# défaut que l'anamnèse : séparateur CR seul, `xref\r1 N\r` au
# lieu de `xref\r0 N+1\r`. Reproductible, pas besoin de fixture.
private def forge_misaligned_pdf : Bytes
  nl = "\r"
  objects = [
    {1, "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] >>"},
    {2, "<< /Length 10 >>#{nl}stream#{nl}BT 1 Tj ET#{nl}endstream"},
    {3, "<< /Type /Page /Parent 4 0 R /MediaBox [0 0 595 842] /Contents 2 0 R >>"},
    {4, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"},
    {5, "<< /Type /Catalog /Pages 4 0 R >>"},
  ]
  io = IO::Memory.new
  io << "%PDF-1.7" << nl
  offsets = {} of Int32 => Int64
  objects.each do |num, body|
    offsets[num] = io.pos.to_i64
    io << num << " 0 obj" << nl << body << nl << "endobj" << nl
  end
  xref_offset = io.pos.to_i64
  io << "xref" << nl
  # BUG VOLONTAIRE : first_obj=1 au lieu de 0. L'entrée free qui
  # devrait appartenir à obj 0 décale toutes les autres d'un rang.
  io << "1 " << (objects.size + 1) << nl
  io << "0000000000 65535 f \r"
  objects.each do |num, _|
    io << ("%010d" % offsets[num]) << " 00000 n \r"
  end
  io << "trailer" << nl
  io << "<< /Size " << (objects.size + 1) << " /Root 5 0 R >>" << nl
  io << "startxref" << nl << xref_offset << nl
  io << "%%EOF" << nl
  io.to_slice
end

describe PDF::Reader do
  describe "récupération de xref décalée" do
    it "lit correctement les pages d'un PDF avec xref décalée (first_obj=1)" do
      data = forge_misaligned_pdf
      reader = PDF::Reader.new(data)

      # Le Catalog (obj 5) pointe sur Pages (obj 4) qui pointe sur la
      # Page (obj 3). Si le Reader a bien récupéré, il doit voir
      # exactement 1 page. Sans récupération, il voyait 0.
      reader.page_count.should eq(1)
      reader.pages.size.should eq(1)
      reader.pages[0].width.should be_close(595.0, 0.5)
      reader.pages[0].height.should be_close(842.0, 0.5)
    end

    it "résout correctement le Catalog malgré le décalage xref" do
      reader = PDF::Reader.new(forge_misaligned_pdf)
      root_ref = reader.@trailer["Root"].as(PDF::Objects::Reference)
      root_ref.object_number.should eq(5)

      root = reader.resolve(root_ref).as(PDF::Objects::Dictionary)
      root.has_key?("Pages").should be_true
      root["Type"].as(PDF::Objects::Name).value.should eq("Catalog")
    end
  end
end
