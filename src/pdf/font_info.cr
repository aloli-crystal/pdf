module PDF
  # Énumère les fontes utilisées par un document PDF — l'équivalent
  # bibliothèque de l'utilitaire `pdffonts` de poppler-utils.
  #
  # Parcourt le dictionnaire `/Resources /Font` de chaque page,
  # déduplique par numéro d'objet et reconstitue les colonnes que
  # `pdffonts` affiche : nom, type de programme, encodage, et les
  # drapeaux *embedded* / *subset* / *unicode*.
  #
  # ```
  # fonts = PDF::FontInfo.list("document.pdf")
  # fonts.each { |f| puts "#{f.name} (#{f.type})" }
  # ```
  #
  # Lecture de métadonnées pure : ne décode AUCUN programme de fonte
  # (cf. `pdf2text` pour le texte, `pdf-validate` pour la conformité).
  struct FontInfo
    # Nom de base de la fonte (/BaseFont), préfixe de subset compris.
    getter name : String

    # Type de programme lisible : "Type 1", "TrueType", "Type 0",
    # "CID TrueType", "Type 3", etc.
    getter type : String

    # Encodage : nom (/Encoding) ou "Custom" pour un dictionnaire,
    # ou le nom de CMap pour une fonte composite.
    getter encoding : String?

    # Programme de fonte embarqué (/FontFile, /FontFile2, /FontFile3) ?
    getter? embedded : Bool

    # Sous-ensemble (préfixe de 6 majuscules + `+` dans /BaseFont) ?
    getter? subset : Bool

    # Carte /ToUnicode présente (texte extractible en Unicode) ?
    getter? to_unicode : Bool

    # Numéro et génération de l'objet indirect du dictionnaire de fonte.
    getter object_number : Int32
    getter generation : Int32

    def initialize(
      @name : String,
      @type : String,
      @encoding : String?,
      @embedded : Bool,
      @subset : Bool,
      @to_unicode : Bool,
      @object_number : Int32,
      @generation : Int32,
    )
    end

    # Ouvre un fichier et liste ses fontes.
    def self.list(path : String, password : String = "") : ::Array(FontInfo)
      list(PDF::Reader.open(path, password))
    end

    # Liste les fontes d'un `PDF::Reader` déjà ouvert, dédupliquées
    # par numéro d'objet et triées par ordre d'apparition.
    def self.list(reader : PDF::Reader) : ::Array(FontInfo)
      seen = {} of Int32 => FontInfo
      order = [] of Int32

      reader.pages.each do |page|
        font_dict = page.resources["Font"]?
        font_dict = reader.resolve(font_dict) if font_dict
        next unless dict = font_dict.as?(PDF::Objects::Dictionary)

        dict.each do |_name, value|
          obj_num, gen = reference_id(value)
          next if obj_num && seen.has_key?(obj_num)

          resolved = reader.resolve(value)
          next unless font = resolved.as?(PDF::Objects::Dictionary)

          info = build(reader, font, obj_num || 0, gen)
          key = obj_num || -(order.size + 1)
          next if seen.has_key?(key)
          seen[key] = info
          order << key
        end
      end

      order.map { |k| seen[k] }
    end

    private def self.reference_id(value : PDF::Objects::Base) : Tuple(Int32?, Int32)
      if ref = value.as?(PDF::Objects::Reference)
        {ref.object_number, ref.generation}
      else
        {nil, 0}
      end
    end

    private def self.build(reader : PDF::Reader, font : PDF::Objects::Dictionary, obj_num : Int32, gen : Int32) : FontInfo
      subtype = name_value(reader, font["Subtype"]?)
      base_font = name_value(reader, font["BaseFont"]?) || "[no name]"

      # Fonte composite : le descripteur et le sous-type réel sont
      # portés par la fonte descendante (CIDFontType0/2).
      descriptor = resolve_dict(reader, font["FontDescriptor"]?)
      real_subtype = subtype
      if subtype == "Type0"
        if descendant = first_descendant(reader, font)
          descriptor ||= resolve_dict(reader, descendant["FontDescriptor"]?)
          real_subtype = name_value(reader, descendant["Subtype"]?) || subtype
        end
      end

      embedded = embedded?(reader, descriptor)
      type = readable_type(real_subtype, descriptor, reader)

      FontInfo.new(
        name: base_font,
        type: type,
        encoding: encoding_label(reader, font),
        embedded: embedded,
        subset: subset?(base_font),
        to_unicode: !(font["ToUnicode"]?).nil?,
        object_number: obj_num,
        generation: gen,
      )
    end

    private def self.first_descendant(reader : PDF::Reader, font : PDF::Objects::Dictionary) : PDF::Objects::Dictionary?
      desc = font["DescendantFonts"]?
      desc = reader.resolve(desc) if desc
      if arr = desc.as?(PDF::Objects::Array)
        return resolve_dict(reader, arr.unsafe_fetch(0)) if arr.size > 0
      end
      nil
    end

    private def self.embedded?(reader : PDF::Reader, descriptor : PDF::Objects::Dictionary?) : Bool
      return false unless descriptor
      {"FontFile", "FontFile2", "FontFile3"}.any? { |k| !(descriptor[k]?).nil? }
    end

    # Traduit le sous-type PDF en libellé lisible proche de `pdffonts`.
    private def self.readable_type(subtype : String?, descriptor : PDF::Objects::Dictionary?, reader : PDF::Reader) : String
      case subtype
      when "Type1"    then "Type 1"
      when "MMType1"  then "MMType1"
      when "Type3"    then "Type 3"
      when "TrueType" then "TrueType"
      when "Type0"    then "Type 0"
      when "CIDFontType0"
        cff = descriptor && !(descriptor["FontFile3"]?).nil?
        cff ? "CID Type 0C" : "CID Type 0"
      when "CIDFontType2" then "CID TrueType"
      else
        subtype || "[unknown]"
      end
    end

    # Étiquette d'encodage : nom direct, "Custom" si dictionnaire,
    # ou le nom de CMap pour une fonte composite (/Encoding nom).
    private def self.encoding_label(reader : PDF::Reader, font : PDF::Objects::Dictionary) : String?
      enc = font["Encoding"]?
      return unless enc
      resolved = reader.resolve(enc)
      case resolved
      when PDF::Objects::Name
        resolved.value
      when PDF::Objects::Dictionary
        # /Encoding dictionnaire : base éventuelle + Differences.
        if base = resolved["BaseEncoding"]?.try { |b| reader.resolve(b).as?(PDF::Objects::Name) }
          base.value
        else
          "Custom"
        end
      end
    end

    private def self.subset?(base_font : String) : Bool
      # Préfixe de subset : 6 majuscules suivies de '+' (ISO 32000-1 §9.6.4).
      return false unless base_font.size > 7
      prefix = base_font[0, 6]
      base_font[6] == '+' && prefix.each_char.all? { |c| c.ascii_uppercase? }
    end

    private def self.resolve_dict(reader : PDF::Reader, obj : PDF::Objects::Base?) : PDF::Objects::Dictionary?
      return unless obj
      reader.resolve(obj).as?(PDF::Objects::Dictionary)
    end

    private def self.name_value(reader : PDF::Reader, obj : PDF::Objects::Base?) : String?
      return unless obj
      reader.resolve(obj).as?(PDF::Objects::Name).try(&.value)
    end
  end
end
