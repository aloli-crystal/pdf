require "option_parser"
require "json"
require "../pdf"

# pdfimages — liste et extrait les images d'un document PDF (port
# Crystal de l'utilitaire poppler-utils du même nom).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short. La table de
# `--list` suit le format de poppler `pdfimages -list`. L'extraction
# produit du JPEG (DCTDecode, tel quel) ou du Netpbm PPM/PGM/PBM
# (FlateDecode), comme poppler par défaut.

usage = <<-USAGE
  Usage : pdfimages <fichier.pdf> [options]
          pdfimages help [<sous-commande>]
          pdfimages --version | -V

  Options :
    -l, --list           Lister les images (défaut)
    -a, --save-all       Extraire toutes les images
    -o, --output PRÉFIXE Préfixe des fichiers extraits (défaut : "image")
    -d, --dir DOSSIER    Dossier de sortie (défaut : dossier courant)
    -p, --password MDP   Mot de passe du document chiffré
    -j, --json           Sortie JSON structurée (avec --list)
    -V, --version        Affiche la version
    -h, --help           Affiche cette aide

  Liste et extrait les images embarquées d'un PDF (XObjects /Image
  des pages et des Form XObjects) à la manière de poppler-utils.
  Lecture pure — le document source n'est jamais modifié.
  USAGE

mode = :list
prefix = "image"
dir = "."
password = ""
json_out = false

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-l", "--list", "List images") { mode = :list }
  op.on("-a", "--save-all", "Extract all images") { mode = :save_all }
  op.on("-o PRÉFIXE", "--output PRÉFIXE", "Output filename prefix") { |v| prefix = v }
  op.on("-d DOSSIER", "--dir DOSSIER", "Output directory") { |v| dir = v }
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-j", "--json", "JSON output") { json_out = true }
  op.on("-V", "--version", "Show version") do
    puts "pdfimages #{PDF::VERSION}"
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
  images = PDF::ImageInfo.list(path, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

if mode == :save_all
  Dir.mkdir_p(dir)
  images.each_with_index do |im, i|
    basename = "#{prefix}-#{(i + 1).to_s.rjust(3, '0')}"
    dest = im.write_to(dir, basename)
    STDERR.puts "Extrait : #{dest} (#{im.width}×#{im.height}, #{im.size} octets)"
  end
  puts "#{images.size} image(s) extraite(s) dans #{dir}/"
  exit 0
end

# Mode liste.
if json_out
  payload = images.map_with_index do |im, i|
    {
      "num"        => i + 1,
      "page"       => im.page,
      "name"       => im.name,
      "width"      => im.width,
      "height"     => im.height,
      "color"      => im.color_space,
      "components" => im.components,
      "bpc"        => im.bits_per_component,
      "filter"     => im.filter,
      "image_mask" => im.image_mask?,
      "size"       => im.size,
      "object_num" => im.object_number,
    }
  end
  puts payload.to_json
  exit 0
end

printf("%-4s %-4s %-6s %-6s %-6s %-6s %-4s %-3s %-7s %-9s %s\n",
  "page", "num", "type", "width", "height", "color", "comp", "bpc", "enc", "object", "size")
puts "-" * 72
images.each_with_index do |im, i|
  type = im.image_mask? ? "mask" : "image"
  printf("%-4d %-4d %-6s %-6d %-6d %-6s %-4d %-3d %-7s %6d %2d %d\n",
    im.page, i + 1, type, im.width, im.height, im.color_space,
    im.components, im.bits_per_component, im.filter || "raw",
    im.object_number, 0, im.size)
end
