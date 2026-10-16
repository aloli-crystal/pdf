require "option_parser"
require "json"
require "../pdf"

# pdfinfo — affiche les métadonnées d'un document PDF (port Crystal
# de l'utilitaire poppler-utils du même nom).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short. La sortie par
# défaut suit le format de poppler `pdfinfo` ; `--json` fournit une
# variante structurée homogène avec `pdf2text --json`.

usage = <<-USAGE
  Usage : pdfinfo <fichier.pdf> [options]
          pdfinfo help [<sous-commande>]
          pdfinfo --version | -V

  Options :
    -p, --password MDP   Mot de passe du document chiffré
    -j, --json           Sortie JSON structurée
    -V, --version        Affiche la version
    -h, --help           Affiche cette aide

  Affiche les métadonnées d'un PDF (titre, auteur, dates, version,
  pages, dimensions, chiffrement, balisage…) à la manière de
  poppler-utils. Lecture pure — aucun rendu, aucune modification.
  USAGE

json_out = false
password = ""

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-j", "--json", "JSON output") { json_out = true }
  op.on("-V", "--version", "Show version") do
    puts "pdfinfo #{PDF::VERSION}"
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

if positional.empty?
  STDERR.puts "Erreur : aucun fichier PDF spécifié."
  STDERR.puts usage
  exit 1
end

path = positional.first

unless File.exists?(path)
  STDERR.puts "Erreur : fichier introuvable : #{path}"
  exit 2
end

begin
  info = PDF::Info.open(path, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

# Formate une date PDF : forme lisible si analysable, brute sinon.
format_date = ->(time : Time?, raw : String?) do
  return "" unless raw
  if time
    time.to_s("%a %b %e %H:%M:%S %Y %z")
  else
    raw
  end
end

# Formate une dimension en points sans zéros superflus.
format_pts = ->(value : Float64) do
  s = "%.3f" % value
  s = s.rstrip('0').rstrip('.') if s.includes?('.')
  s
end

if json_out
  size = info.page_size
  payload = {
    "title"           => info.title,
    "subject"         => info.subject,
    "keywords"        => info.keywords,
    "author"          => info.author,
    "creator"         => info.creator,
    "producer"        => info.producer,
    "creation_date"   => info.creation_date.try(&.to_rfc3339),
    "mod_date"        => info.mod_date.try(&.to_rfc3339),
    "custom_metadata" => info.custom,
    "metadata_stream" => info.metadata_stream?,
    "tagged"          => info.tagged?,
    "form"            => info.acroform? ? "AcroForm" : "none",
    "pages"           => info.page_count,
    "encrypted"       => info.encrypted?,
    "page_width"      => size.try(&.[0]),
    "page_height"     => size.try(&.[1]),
    "page_size_name"  => info.page_size_name,
    "page_rot"        => info.page_rot,
    "file_size"       => info.file_size,
    "pdf_version"     => info.version,
  }
  puts payload.to_json
  exit 0
end

# Sortie texte, format poppler `pdfinfo`.
emit = ->(label : String, value : String?) do
  return unless value && !value.empty?
  printf("%-16s %s\n", "#{label}:", value)
end

emit.call("Title", info.title)
emit.call("Subject", info.subject)
emit.call("Keywords", info.keywords)
emit.call("Author", info.author)
emit.call("Creator", info.creator)
emit.call("Producer", info.producer)
emit.call("CreationDate", format_date.call(info.creation_date, info.creation_date_raw))
emit.call("ModDate", format_date.call(info.mod_date, info.mod_date_raw))

printf("%-16s %s\n", "Custom Metadata:", info.custom.empty? ? "no" : "yes")
printf("%-16s %s\n", "Metadata Stream:", info.metadata_stream? ? "yes" : "no")
printf("%-16s %s\n", "Tagged:", info.tagged? ? "yes" : "no")
printf("%-16s %s\n", "Form:", info.acroform? ? "AcroForm" : "none")
printf("%-16s %d\n", "Pages:", info.page_count)
printf("%-16s %s\n", "Encrypted:", info.encrypted? ? "yes" : "no")

if size = info.page_size
  name = info.page_size_name
  suffix = name ? " (#{name})" : ""
  printf("%-16s %s x %s pts%s\n", "Page size:",
    format_pts.call(size[0]), format_pts.call(size[1]), suffix)
end

printf("%-16s %d\n", "Page rot:", info.page_rot)
if fs = info.file_size
  printf("%-16s %d bytes\n", "File size:", fs)
end
printf("%-16s %s\n", "PDF version:", info.version)
