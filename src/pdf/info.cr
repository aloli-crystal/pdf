module PDF
  # Extrait les métadonnées d'un document PDF existant — l'équivalent
  # bibliothèque de l'utilitaire `pdfinfo` de poppler-utils.
  #
  # `PDF::Info` lit le dictionnaire `/Info`, le `/Root` (catalogue),
  # le `/Encrypt` du trailer et la première page pour reconstituer les
  # champs qu'affiche `pdfinfo` : titre, auteur, dates, version PDF,
  # nombre de pages, dimensions, rotation, chiffrement, balisage, etc.
  #
  # ```
  # info = PDF::Info.open("document.pdf")
  # info.title          # => "Mon rapport"
  # info.page_count     # => 12
  # info.page_size      # => {595.276, 841.89}
  # info.page_size_name # => "A4"
  # ```
  #
  # Ne rend AUCUN contenu : c'est de la lecture de métadonnées pure,
  # dans la lignée de `pdf2text` (extraction) et `pdf-validate`
  # (conformité). Le rendu raster (`pdftoppm`) est hors périmètre.
  struct Info
    # Champs du dictionnaire /Info (nil si absents).
    getter title : String?
    getter author : String?
    getter subject : String?
    getter keywords : String?
    getter creator : String?
    getter producer : String?

    # Dates /Info, brutes (chaîne `D:…`) et analysées.
    getter creation_date_raw : String?
    getter mod_date_raw : String?
    getter creation_date : Time?
    getter mod_date : Time?

    # Entrées /Info hors clés standard (métadonnées personnalisées).
    getter custom : Hash(String, String)

    # Version du document (ex. "1.7").
    getter version : String

    # Nombre de pages.
    getter page_count : Int32

    # Dimensions de la première page en points PDF (largeur, hauteur),
    # nil si le document n'a pas de page.
    getter page_size : Tuple(Float64, Float64)?

    # Rotation de la première page en degrés (0, 90, 180, 270).
    getter page_rot : Int32

    # Document chiffré ?
    getter? encrypted : Bool

    # Description du chiffrement (algorithme + longueur de clé), si chiffré.
    getter encryption : String?

    # Document balisé (Tagged PDF : /MarkInfo /Marked true) ?
    getter? tagged : Bool

    # Présence d'un flux de métadonnées XMP (/Root /Metadata) ?
    getter? metadata_stream : Bool

    # Présence d'un formulaire interactif (/Root /AcroForm) ?
    getter? acroform : Bool

    # Taille du fichier en octets (nil si lu depuis un IO sans taille).
    getter file_size : Int64?

    def initialize(
      @title : String?,
      @author : String?,
      @subject : String?,
      @keywords : String?,
      @creator : String?,
      @producer : String?,
      @creation_date_raw : String?,
      @mod_date_raw : String?,
      @creation_date : Time?,
      @mod_date : Time?,
      @custom : Hash(String, String),
      @version : String,
      @page_count : Int32,
      @page_size : Tuple(Float64, Float64)?,
      @page_rot : Int32,
      @encrypted : Bool,
      @encryption : String?,
      @tagged : Bool,
      @metadata_stream : Bool,
      @acroform : Bool,
      @file_size : Int64?,
    )
    end

    # Ouvre un fichier et en extrait les métadonnées.
    def self.open(path : String, password : String = "") : Info
      reader = PDF::Reader.open(path, password)
      from(reader, File.size(path).to_i64)
    end

    # Extrait les métadonnées d'un `PDF::Reader` déjà ouvert.
    def self.from(reader : PDF::Reader, file_size : Int64? = nil) : Info
      info_dict = resolve_dict(reader, reader.trailer["Info"]?)
      root = resolve_dict(reader, reader.trailer["Root"]?)

      # Clés standard du dictionnaire /Info (ISO 32000-1 §14.3.3).
      standard = {"Title", "Author", "Subject", "Keywords",
                  "Creator", "Producer", "CreationDate", "ModDate", "Trapped"}
      custom = {} of String => String
      if info_dict
        info_dict.each do |name, value|
          next if standard.includes?(name.value)
          if str = reader.resolve(value).as?(PDF::Objects::Str)
            custom[name.value] = decode_text_string(str.value)
          end
        end
      end

      creation_raw = string_field(reader, info_dict, "CreationDate")
      mod_raw = string_field(reader, info_dict, "ModDate")

      # Dimensions et rotation depuis la première page.
      page_size = nil
      page_rot = 0
      if first = reader.pages.first?
        page_size = {first.width, first.height}
        page_rot = page_rotation(reader, first)
      end

      encrypt = reader.trailer["Encrypt"]?
      encrypted = !encrypt.nil?

      Info.new(
        title: string_field(reader, info_dict, "Title"),
        author: string_field(reader, info_dict, "Author"),
        subject: string_field(reader, info_dict, "Subject"),
        keywords: string_field(reader, info_dict, "Keywords"),
        creator: string_field(reader, info_dict, "Creator"),
        producer: string_field(reader, info_dict, "Producer"),
        creation_date_raw: creation_raw,
        mod_date_raw: mod_raw,
        creation_date: parse_date(creation_raw),
        mod_date: parse_date(mod_raw),
        custom: custom,
        version: reader.version,
        page_count: reader.page_count,
        page_size: page_size,
        page_rot: page_rot,
        encrypted: encrypted,
        encryption: nil,
        tagged: tagged?(reader, root),
        metadata_stream: !(root.try(&.["Metadata"]?)).nil?,
        acroform: !(root.try(&.["AcroForm"]?)).nil?,
        file_size: file_size,
      )
    end

    # Nom normalisé de la dimension de page (A4, Letter, Legal…),
    # ou nil si elle ne correspond à aucun format standard.
    def page_size_name : String?
      size = @page_size
      return unless size
      w, h = size
      # On compare indépendamment de l'orientation.
      lo, hi = {w, h}.minmax
      STANDARD_SIZES.each do |name, dims|
        sw, sh = dims
        return name if (lo - sw).abs <= SIZE_TOLERANCE && (hi - sh).abs <= SIZE_TOLERANCE
      end
      nil
    end

    # Formats standard (largeur, hauteur) en points, petit côté d'abord.
    STANDARD_SIZES = {
      "A6"      => {297.638, 419.528},
      "A5"      => {419.528, 595.276},
      "A4"      => {595.276, 841.89},
      "A3"      => {841.89, 1190.55},
      "A2"      => {1190.55, 1683.78},
      "Letter"  => {612.0, 792.0},
      "Legal"   => {612.0, 1008.0},
      "Tabloid" => {792.0, 1224.0},
      "Ledger"  => {792.0, 1224.0},
    }

    # Tolérance de comparaison des dimensions (points).
    SIZE_TOLERANCE = 3.0

    private def self.resolve_dict(reader : PDF::Reader, obj : PDF::Objects::Base?) : PDF::Objects::Dictionary?
      return unless obj
      resolved = reader.resolve(obj)
      resolved.as?(PDF::Objects::Dictionary)
    end

    private def self.string_field(reader : PDF::Reader, dict : PDF::Objects::Dictionary?, key : String) : String?
      return unless dict
      value = dict[key]?
      return unless value
      str = reader.resolve(value).as?(PDF::Objects::Str)
      return unless str
      decode_text_string(str.value)
    end

    # Décode une chaîne texte PDF (ISO 32000-1 §7.9.2.2) vers UTF-8 :
    # UTF-16BE/LE si BOM présent, sinon PDFDocEncoding (approximé par
    # ISO-8859-1, identique au Latin-1 sur la plage des accents usuels).
    # `str.value` conserve les octets bruts même lorsqu'ils ne sont pas
    # de l'UTF-8 valide — on les relit via `to_slice`.
    def self.decode_text_string(raw : String) : String
      bytes = raw.to_slice
      if bytes.size >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF
        String.new(bytes[2..], "UTF-16BE", invalid: :skip)
      elsif bytes.size >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE
        String.new(bytes[2..], "UTF-16LE", invalid: :skip)
      elsif raw.valid_encoding?
        raw
      else
        String.new(bytes, "ISO-8859-1", invalid: :skip)
      end
    rescue
      raw
    end

    private def self.page_rotation(reader : PDF::Reader, page : PDF::ReaderPage) : Int32
      rotate = page.page_dict["Rotate"]?
      rotate = reader.resolve(rotate) if rotate
      if num = rotate.as?(PDF::Objects::Number)
        return num.to_i64.to_i % 360
      end
      0
    end

    private def self.tagged?(reader : PDF::Reader, root : PDF::Objects::Dictionary?) : Bool
      return false unless root
      mark_info = root["MarkInfo"]?
      return false unless mark_info
      mark_info = reader.resolve(mark_info)
      if dict = mark_info.as?(PDF::Objects::Dictionary)
        if marked = dict["Marked"]?.try { |m| reader.resolve(m).as?(PDF::Objects::Boolean) }
          return marked.value
        end
      end
      false
    end

    # Analyse une date PDF `D:YYYYMMDDHHmmSSOHH'mm'` (ISO 32000-1
    # §7.9.4). Tous les champs après l'année sont optionnels. Retourne
    # nil si la chaîne est absente ou non analysable.
    def self.parse_date(raw : String?) : Time?
      return unless raw
      s = raw.lchop("D:")
      return if s.size < 4

      year = s[0, 4].to_i?
      return unless year
      month = (s[4, 2]?.try(&.to_i?)) || 1
      day = (s[6, 2]?.try(&.to_i?)) || 1
      hour = (s[8, 2]?.try(&.to_i?)) || 0
      minute = (s[10, 2]?.try(&.to_i?)) || 0
      second = (s[12, 2]?.try(&.to_i?)) || 0

      location = parse_offset(s[14..]?) || Time::Location::UTC

      Time.local(year, month, day, hour, minute, second, location: location)
    rescue
      nil
    end

    # Analyse le décalage horaire `O HH ' mm '` (O ∈ {+, -, Z}).
    private def self.parse_offset(tail : String?) : Time::Location?
      return Time::Location::UTC unless tail && !tail.empty?
      sign = tail[0]
      return Time::Location::UTC if sign == 'Z'
      return unless sign == '+' || sign == '-'

      digits = tail[1..].gsub('\'', "")
      oh = (digits[0, 2]?.try(&.to_i?)) || 0
      om = (digits[2, 2]?.try(&.to_i?)) || 0
      seconds = (oh * 3600 + om * 60) * (sign == '-' ? -1 : 1)
      Time::Location.fixed(seconds)
    end
  end
end
