require "option_parser"
require "json"
require "../pdf"

# pdffonts — liste les fontes d'un document PDF (port Crystal de
# l'utilitaire poppler-utils du même nom).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short. La table par
# défaut suit le format de poppler `pdffonts` ; `--json` fournit une
# variante structurée homogène avec le reste de la suite.

usage = <<-USAGE
  Usage : pdffonts <fichier.pdf> [options]
          pdffonts help [<sous-commande>]
          pdffonts --version | -V

  Options :
    -p, --password MDP   Mot de passe du document chiffré
    -j, --json           Sortie JSON structurée
    -V, --version        Affiche la version
    -h, --help           Affiche cette aide

  Liste les fontes d'un PDF (nom, type, encodage, embarquée,
  sous-ensemble, Unicode, identifiant d'objet) à la manière de
  poppler-utils. Lecture pure — aucun rendu, aucune modification.
  USAGE

json_out = false
password = ""

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-j", "--json", "JSON output") { json_out = true }
  op.on("-V", "--version", "Show version") do
    puts "pdffonts #{PDF::VERSION}"
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
  fonts = PDF::FontInfo.list(path, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

if json_out
  payload = fonts.map do |f|
    {
      "name"       => f.name,
      "type"       => f.type,
      "encoding"   => f.encoding,
      "embedded"   => f.embedded?,
      "subset"     => f.subset?,
      "unicode"    => f.to_unicode?,
      "object_num" => f.object_number,
      "object_gen" => f.generation,
    }
  end
  puts payload.to_json
  exit 0
end

# Table texte, format poppler `pdffonts`.
yn = ->(b : Bool) { b ? "yes" : "no" }

printf("%-36s %-17s %-16s %-3s %-3s %-3s %9s\n",
  "name", "type", "encoding", "emb", "sub", "uni", "object ID")
puts "#{"-" * 36} #{"-" * 17} #{"-" * 16} #{"-" * 3} #{"-" * 3} #{"-" * 3} #{"-" * 9}"

fonts.each do |f|
  printf("%-36s %-17s %-16s %-3s %-3s %-3s %6d %2d\n",
    f.name, f.type, f.encoding || "",
    yn.call(f.embedded?), yn.call(f.subset?), yn.call(f.to_unicode?),
    f.object_number, f.generation)
end
