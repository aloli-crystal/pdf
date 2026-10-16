require "option_parser"
require "json"
require "../pdf"

# pdfdetach — liste et extrait les fichiers attachés d'un document PDF
# (port Crystal de l'utilitaire poppler-utils du même nom).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short. La sortie de
# `--list` suit le format de poppler `pdfdetach`.

usage = <<-USAGE
  Usage : pdfdetach <fichier.pdf> [options]
          pdfdetach help [<sous-commande>]
          pdfdetach --version | -V

  Options :
    -l, --list           Lister les fichiers attachés (défaut)
    -s, --save N         Extraire le fichier n° N (1-based)
    -a, --save-all       Extraire tous les fichiers attachés
    -o, --output CHEMIN  Fichier de sortie (--save) ou dossier (--save-all)
    -p, --password MDP   Mot de passe du document chiffré
    -j, --json           Sortie JSON structurée (avec --list)
    -V, --version        Affiche la version
    -h, --help           Affiche cette aide

  Liste et extrait les fichiers embarqués d'un PDF (arbre
  /EmbeddedFiles, associated files /AF de PDF/A-3, annotations
  /FileAttachment) à la manière de poppler-utils. Lecture pure —
  le document source n'est jamais modifié.
  USAGE

mode = :list
save_index = 0
output : String? = nil
password = ""
json_out = false

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-l", "--list", "List attachments") { mode = :list }
  op.on("-s N", "--save N", "Save attachment N") do |v|
    mode = :save
    save_index = v.to_i? || 0
  end
  op.on("-a", "--save-all", "Save all attachments") { mode = :save_all }
  op.on("-o CHEMIN", "--output CHEMIN", "Output file or directory") { |v| output = v }
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-j", "--json", "JSON output") { json_out = true }
  op.on("-V", "--version", "Show version") do
    puts "pdfdetach #{PDF::VERSION}"
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
  files = PDF::AttachedFile.list(path, password)
rescue PDF::EncryptedPdfError
  STDERR.puts "Erreur : document chiffré — fournissez -p / --password."
  exit 3
rescue ex
  STDERR.puts "Erreur de lecture : #{ex.message}"
  exit 3
end

# Écrit les octets d'un attachement vers un chemin donné.
write_file = ->(file : PDF::AttachedFile, dest : String) do
  File.write(dest, file.data)
  STDERR.puts "Extrait : #{dest} (#{file.data.size} octets)"
end

case mode
when :save
  if save_index < 1 || save_index > files.size
    STDERR.puts "Erreur : index #{save_index} hors limites (#{files.size} fichier(s))."
    exit 4
  end
  file = files[save_index - 1]
  out_path = output
  dest = out_path || file.name
  write_file.call(file, dest)
when :save_all
  out_dir = output
  dir = out_dir || "."
  Dir.mkdir_p(dir)
  files.each { |f| write_file.call(f, File.join(dir, File.basename(f.name))) }
  puts "#{files.size} fichier(s) extrait(s) dans #{dir}/"
else # :list
  if json_out
    payload = files.map_with_index do |f, i|
      {
        "index"        => i + 1,
        "name"         => f.name,
        "description"  => f.description,
        "mime_type"    => f.mime_type,
        "size"         => f.size,
        "relationship" => f.relationship,
        "object_num"   => f.object_number,
      }
    end
    puts payload.to_json
  else
    puts "#{files.size} embedded file#{files.size == 1 ? "" : "s"}"
    files.each_with_index do |f, i|
      line = String.build do |io|
        io << (i + 1) << ": " << f.name
        io << " (" << f.size << " octets)" if f.size
        io << " [" << f.relationship << "]" if f.relationship
      end
      puts line
    end
  end
end
