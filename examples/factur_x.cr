#!/usr/bin/env crystal
#
# Démo : génère un PDF avec un XML Factur-X embarqué en mode "Data".
# C'est la base d'une facture électronique conforme à la norme
# EN 16931 / Factur-X (CIUS française), sous réserve que le XML
# attaché respecte le schéma BASIC / EN 16931 / EXTENDED.
#
# Lancement :
#   crystal run examples/factur_x.cr

require "../src/pdf"

# Minimal Factur-X XML stub (le contenu réel doit suivre le schéma
# EN 16931 ; ici on attache un placeholder pour illustrer la
# mécanique d'embedding).
factur_xml = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100">
    <rsm:ExchangedDocument>
      <ram:ID>2026-DEMO-001</ram:ID>
      <ram:TypeCode>380</ram:TypeCode>
      <ram:IssueDateTime>
        <udt:DateTimeString format="102">20260601</udt:DateTimeString>
      </ram:IssueDateTime>
    </rsm:ExchangedDocument>
  </rsm:CrossIndustryInvoice>
  XML

pdf = PDF::Document.new
pdf.title = "Facture Démo ALOLI Factur-X"
pdf.author = "aloli-crystal/pdf"

pdf.page(:a4) do |p|
  p.font "Helvetica", size: 18
  p.text "Facture démo Factur-X", at: {72, 780}

  p.font "Helvetica", size: 11
  p.text "Cette démo génère un PDF/A-3-compatible (côté embedding)", at: {72, 750}
  p.text "avec un XML Factur-X attaché en mode `/AFRelationship /Data`.", at: {72, 735}
  p.text "Le rendu visible est un placeholder.", at: {72, 705}
end

pdf.attach_file(
  bytes: factur_xml.to_slice,
  name: "factur-x.xml",
  description: "Factur-X invoice data (placeholder)",
  relationship: :data,
  mime_type: "application/xml",
)

# Pour une facture vraiment PDF/A-3 il faudrait aussi un output
# intent ; on l'ajoute pour boucler la démo.
pdf.output_intent = PDF::OutputIntent.srgb

output = "factur_x_demo.pdf"
pdf.save(output)
puts "PDF généré : #{output} (#{File.size(output)} octets)"
puts "Le XML Factur-X est embarqué comme pièce jointe (/AF /Data)."
puts "Pour extraire : pdfdetach -saveall #{output}"
