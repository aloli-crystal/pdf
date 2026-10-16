require "option_parser"
require "../pdf"

# pdfattach — attache un fichier à un document PDF (port Crystal de
# l'utilitaire poppler-utils du même nom).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short. Le fichier est
# ajouté à l'arbre /EmbeddedFiles ET à /AF (PDF/A-3, Factur-X) via une
# mise à jour incrémentale — le document d'origine reste intact, le
# résultat est écrit dans un nouveau fichier.

relationships = PDF::FileSpec::VALID_RELATIONSHIPS.keys.map(&.to_s).join(", ")

usage = <<-USAGE
  Usage : pdfattach <document.pdf> <fichier-à-joindre> [options]
          pdfattach help [<sous-commande>]
          pdfattach --version | -V

  Options :
    -o, --output PDF      PDF de sortie (défaut : <document>-attached.pdf)
    -n, --name NOM        Nom de la pièce jointe (défaut : nom du fichier)
    -d, --desc TEXTE      Description de la pièce jointe
    -m, --mime TYPE       Type MIME (ex. application/xml)
    -r, --relationship R  Relation /AFRelationship (#{relationships})
    -p, --password MDP    Mot de passe du document chiffré
    -V, --version         Affiche la version
    -h, --help            Affiche cette aide

  Attache un fichier à un PDF (arbre /EmbeddedFiles + associated
  files /AF, PDF/A-3 / Factur-X) par mise à jour incrémentale. Le
  document d'origine n'est pas modifié ; le résultat est écrit dans
  un nouveau fichier.
  USAGE

output : String? = nil
att_name : String? = nil
description : String? = nil
mime_type : String? = nil
relationship = "unspecified"
password = ""

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-o PDF", "--output PDF", "Output PDF") { |v| output = v }
  op.on("-n NOM", "--name NOM", "Attachment name") { |v| att_name = v }
  op.on("-d TEXTE", "--desc TEXTE", "Description") { |v| description = v }
  op.on("-m TYPE", "--mime TYPE", "MIME type") { |v| mime_type = v }
  op.on("-r R", "--relationship R", "AFRelationship") { |v| relationship = v }
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-V", "--version", "Show version") do
    puts "pdfattach #{PDF::VERSION}"
    exit 0
  end
  op.on("-h", "--help", "Show this help") do
    puts usage
    exit 0
  end
  op.invalid_option do |flag|
    STDERR.puts "Option inconnue : #{flag}"
    STDERR.puts usage
    exit 1
  end
end

positional = [] of String
parser.unknown_args { |args| positional = args }
parser.parse(ARGV)

# Convention ALOLI : `help [<sous-commande>]` positionnel.
if !positional.empty? && positional.first == "help"
  puts usage
  exit 0
end

if positional.size < 2
  STDERR.puts "Erreur : il faut un document PDF et un fichier à joindre."
  STDERR.puts usage
  exit 1
end

pdf_path = positional[0]
file_path = positional[1]

unless File.exists?(pdf_path)
  STDERR.puts "Erreur : PDF introuvable : #{pdf_path}"
  exit 2
end
unless File.exists?(file_path)
  STDERR.puts "Erreur : fichier à joindre introuvable : #{file_path}"
  exit 2
end

# Valider et convertir la relation /AFRelationship (chaîne → symbole).
rel_sym = PDF::FileSpec::VALID_RELATIONSHIPS.keys.find { |k| k.to_s == relationship }
unless rel_sym
  STDERR.puts "Erreur : relation inconnue « #{relationship} » (valides : #{relationships})."
  exit 1
end

out_opt = output
dest = out_opt || begin
  ext = File.extname(pdf_path)
  base = pdf_path[0, pdf_path.size - ext.size]
  "#{base}-attached#{ext}"
end

chosen_name = att_name
name = chosen_name || File.basename(file_path)

begin
  reader = PDF::Reader.open(pdf_path, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

bytes = File.read(file_path).to_slice
stat = File.info(file_path)

PDF::AttachedFile.attach(
  reader, bytes, name,
  description: description,
  relationship: rel_sym,
  mime_type: mime_type,
  creation_date: stat.modification_time,
  modification_date: stat.modification_time,
)

reader.save(dest)
puts "Pièce jointe « #{name} » (#{bytes.size} octets) ajoutée → #{dest}"
