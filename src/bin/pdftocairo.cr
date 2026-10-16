require "option_parser"
require "../pdf"

# pdftocairo — rend les pages d'un PDF en images (port Crystal de
# l'utilitaire poppler-utils du même nom), via le rasterizer natif
# `PDF::Raster` — SANS cairo ni ghostscript.
#
# MVP : rendu vectoriel, sortie PNG. Texte et images : paliers
# suivants. Formats vectoriels de poppler (-ps/-pdf/-svg) hors
# périmètre (relais `pdftops` disponible pour le PostScript).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short.

usage = <<-USAGE
  Usage : pdftocairo <fichier.pdf> [<sortie>] [options]
          pdftocairo help [<sous-commande>]
          pdftocairo --version | -V

  Options :
    -P, --png             Sortie PNG (défaut)
    -r, --resolution DPI  Résolution en points par pouce (défaut 150)
    -a, --antialias N     Supersampling anti-aliasing 1-4 (défaut 3)
    -f, --first N         Première page
    -l, --last N          Dernière page
    -s, --singlefile      Une seule page → écrit directement <sortie>
    -p, --password MDP    Mot de passe du document chiffré
    -V, --version         Affiche la version
    -h, --help            Affiche cette aide

  Rend les pages en PNG via le rasterizer natif (pur Crystal). Sans
  --singlefile, écrit <sortie>-<NN>.png. MVP vectoriel : le texte et
  les images ne sont pas encore rendus.
  USAGE

dpi = PDF::Raster::DEFAULT_DPI
antialias = 3
first_page : Int32? = nil
last_page : Int32? = nil
single = false
password = ""

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-P", "--png", "PNG output") { }
  op.on("-r DPI", "--resolution DPI", "Resolution") { |v| dpi = v.to_i? || dpi }
  op.on("-a N", "--antialias N", "Anti-aliasing factor") { |v| antialias = (v.to_i? || 3).clamp(1, 4) }
  op.on("-f N", "--first N", "First page") { |v| first_page = v.to_i? }
  op.on("-l N", "--last N", "Last page") { |v| last_page = v.to_i? }
  op.on("-s", "--singlefile", "Single file output") { single = true }
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-V", "--version", "Show version") do
    puts "pdftocairo #{PDF::VERSION}"
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

if !positional.empty? && positional.first == "help"
  puts usage
  exit 0
end

if positional.empty?
  STDERR.puts "Erreur : aucun fichier PDF spécifié."
  STDERR.puts usage
  exit 1
end

input = positional[0]
unless File.exists?(input)
  STDERR.puts "Erreur : fichier introuvable : #{input}"
  exit 2
end

out_arg = positional[1]?
base = out_arg || begin
  ext = File.extname(input)
  input[0, input.size - ext.size]
end

begin
  reader = PDF::Reader.open(input, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

count = reader.page_count
fp = first_page
lp = last_page
from = (fp || 1).clamp(1, count)
to = (lp || count).clamp(1, count)
to = from if single
digits = Math.max(2, count.to_s.size)

(from..to).each do |n|
  canvas = PDF::Raster.render_page(reader, n - 1, dpi: dpi, supersample: antialias)
  dest = single ? (base.ends_with?(".png") ? base : "#{base}.png") : "#{base}-#{n.to_s.rjust(digits, '0')}.png"
  canvas.save_png(dest)
  STDERR.puts "Rendu : #{dest} (#{canvas.width}×#{canvas.height})"
end
