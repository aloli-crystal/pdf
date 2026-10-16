module PDF
  # Énumère et extrait les images (XObjects de sous-type /Image) d'un
  # document PDF — l'équivalent bibliothèque de l'utilitaire
  # `pdfimages` de poppler-utils.
  #
  # Parcourt le `/Resources /XObject` de chaque page (ISO 32000-1
  # § 8.8) et descend récursivement dans les Form XObjects. Pour
  # chaque image, expose les métadonnées (dimensions, espace
  # colorimétrique, profondeur, filtre) et, à la demande, les octets.
  #
  # ```
  # images = PDF::ImageInfo.list("document.pdf")
  # images.each { |im| puts "#{im.width}×#{im.height} #{im.color_space}" }
  # ```
  #
  # Extraction (lecture pure, aucune modification du document) :
  # - images `/DCTDecode` : octets JPEG restitués tels quels (`.jpg`) ;
  # - images `/FlateDecode` : échantillons bruts exportés en PPM/PGM/PBM
  #   (formats Netpbm, comme poppler par défaut) ;
  # - autres filtres (CCITT, JPX, JBIG2…) : octets bruts conservés.
  struct ImageInfo
    # Numéro de page (1-based) où l'image a été rencontrée.
    getter page : Int32

    # Nom de ressource de l'XObject (ex. "Im0").
    getter name : String

    # Dimensions en pixels (/Width, /Height).
    getter width : Int32
    getter height : Int32

    # Bits par composante (/BitsPerComponent ; 1 pour un masque).
    getter bits_per_component : Int32

    # Espace colorimétrique normalisé : "rgb", "gray", "cmyk", "icc",
    # "index", "sep", "devn", "lab", "mask", ou le nom brut sinon.
    getter color_space : String

    # Nombre de composantes couleur.
    getter components : Int32

    # Filtre de codage : "jpeg", "flate", "ccitt", "jpx", "jbig2",
    # "lzw", "rle", ou nil (données brutes non filtrées).
    getter filter : String?

    # Image-masque de pochoir (/ImageMask true) ?
    getter? image_mask : Bool

    # Taille des octets du flux (encodés sur disque).
    getter size : Int32

    # Numéro d'objet indirect de l'XObject image.
    getter object_number : Int32

    @reader : PDF::Reader
    @stream : PDF::Objects::Stream

    def initialize(
      @page : Int32,
      @name : String,
      @width : Int32,
      @height : Int32,
      @bits_per_component : Int32,
      @color_space : String,
      @components : Int32,
      @filter : String?,
      @image_mask : Bool,
      @size : Int32,
      @object_number : Int32,
      @reader : PDF::Reader,
      @stream : PDF::Objects::Stream,
    )
    end

    # Octets du flux image. Décodés (échantillons bruts) pour
    # FlateDecode ; encodés tels quels (ex. JPEG) pour les filtres que
    # le parseur ne sait pas inverser.
    def data : Bytes
      @stream.data
    end

    # `true` si `data` contient des octets décodés (échantillons), `false`
    # s'ils sont encore encodés (JPEG, CCITT, JPX…).
    def decoded? : Bool
      @stream.decoded
    end

    # Extension de fichier suggérée selon le filtre et l'espace couleur.
    def extension : String
      case @filter
      when "jpeg" then "jpg"
      when "jpx"  then "jp2"
      when "jbig2", "ccitt"
        "raw"
      else
        # Données décodées → format Netpbm selon l'espace couleur.
        if @image_mask || (@bits_per_component == 1 && @components == 1)
          "pbm"
        elsif @components == 1
          "pgm"
        elsif @components == 3
          "ppm"
        else
          "raw"
        end
      end
    end

    # Écrit l'image dans `dir` sous `basename` + l'extension adéquate.
    # Retourne le chemin écrit. Les images Netpbm reçoivent l'en-tête
    # PPM/PGM/PBM ; les JPEG et bruts sont copiés tels quels.
    def write_to(dir : String, basename : String) : String
      ext = extension
      dest = File.join(dir, "#{basename}.#{ext}")
      case ext
      when "ppm", "pgm", "pbm"
        File.open(dest, "wb") { |io| write_netpbm(io, ext) }
      else
        File.write(dest, @stream.data)
      end
      dest
    end

    # Ouvre un fichier et liste ses images.
    def self.list(path : String, password : String = "") : ::Array(ImageInfo)
      list(PDF::Reader.open(path, password))
    end

    # Liste les images d'un `PDF::Reader` déjà ouvert, dans l'ordre des
    # pages, dédupliquées par numéro d'objet.
    def self.list(reader : PDF::Reader) : ::Array(ImageInfo)
      seen = Set(Int32).new
      result = [] of ImageInfo

      reader.pages.each_with_index do |page, idx|
        collect_from_resources(reader, page.resources, idx + 1, seen, result, 0)
      end

      result
    end

    # Parcourt un dictionnaire de ressources : XObjects /Image directs +
    # récursion dans les Form XObjects (avec garde de profondeur).
    private def self.collect_from_resources(
      reader : PDF::Reader,
      resources : PDF::Objects::Dictionary,
      page : Int32,
      seen : Set(Int32),
      result : ::Array(ImageInfo),
      depth : Int32,
    ) : Nil
      return if depth > 8
      xobjects = resources["XObject"]?
      xobjects = reader.resolve(xobjects) if xobjects
      dict = xobjects.as?(PDF::Objects::Dictionary)
      return unless dict

      dict.each do |name, ref|
        obj_num = ref.as?(PDF::Objects::Reference).try(&.object_number) || 0
        stream = reader.resolve(ref).as?(PDF::Objects::Stream)
        next unless stream

        subtype = name_value(reader, stream["Subtype"]?)
        case subtype
        when "Image"
          next if obj_num != 0 && seen.includes?(obj_num)
          seen.add(obj_num) if obj_num != 0
          if info = build(reader, stream, name.value, page, obj_num)
            result << info
          end
        when "Form"
          # Form XObject : descendre dans ses propres ressources.
          form_res = stream["Resources"]?
          form_res = reader.resolve(form_res) if form_res
          if fr = form_res.as?(PDF::Objects::Dictionary)
            collect_from_resources(reader, fr, page, seen, result, depth + 1)
          end
        end
      end
    end

    private def self.build(reader : PDF::Reader, stream : PDF::Objects::Stream, name : String, page : Int32, obj_num : Int32) : ImageInfo?
      width = int_value(reader, stream["Width"]?)
      height = int_value(reader, stream["Height"]?)
      return unless width && height

      image_mask = stream["ImageMask"]?.try { |m| reader.resolve(m).as?(PDF::Objects::Boolean).try(&.value) } || false
      bpc = int_value(reader, stream["BitsPerComponent"]?) || (image_mask ? 1 : 8)

      color_space, components = if image_mask
                                  {"mask", 1}
                                else
                                  classify_color_space(reader, stream["ColorSpace"]?)
                                end

      filter = classify_filter(reader, stream["Filter"]?)

      ImageInfo.new(
        page: page,
        name: name,
        width: width,
        height: height,
        bits_per_component: bpc,
        color_space: color_space,
        components: components,
        filter: filter,
        image_mask: image_mask,
        size: stream.data.size,
        object_number: obj_num,
        reader: reader,
        stream: stream,
      )
    end

    # Normalise l'espace colorimétrique d'une image vers {libellé,
    # nombre de composantes}. Gère les noms simples et les tableaux
    # (ICCBased, Indexed, Separation, DeviceN, CalRGB/Gray, Lab).
    private def self.classify_color_space(reader : PDF::Reader, cs : PDF::Objects::Base?) : Tuple(String, Int32)
      return {"gray", 1} unless cs
      resolved = reader.resolve(cs)

      case resolved
      when PDF::Objects::Name
        case resolved.value
        when "DeviceRGB", "RGB", "CalRGB" then {"rgb", 3}
        when "DeviceGray", "G", "CalGray" then {"gray", 1}
        when "DeviceCMYK", "CMYK"         then {"cmyk", 4}
        else                                   {resolved.value.downcase, 1}
        end
      when PDF::Objects::Array
        return {"gray", 1} if resolved.size == 0
        head = reader.resolve(resolved.unsafe_fetch(0)).as?(PDF::Objects::Name).try(&.value)
        case head
        when "ICCBased"
          n = 0
          if resolved.size > 1 && (st = reader.resolve(resolved.unsafe_fetch(1)).as?(PDF::Objects::Stream))
            n = int_value(reader, st["N"]?) || 0
          end
          {"icc", n}
        when "Indexed", "I"  then {"index", 1}
        when "Separation"    then {"sep", 1}
        when "DeviceN"       then {"devn", devicen_count(reader, resolved)}
        when "CalRGB", "Lab" then {head == "Lab" ? "lab" : "rgb", 3}
        when "CalGray"       then {"gray", 1}
        else                      {(head || "?").downcase, 1}
        end
      else
        {"gray", 1}
      end
    end

    private def self.devicen_count(reader : PDF::Reader, cs : PDF::Objects::Array) : Int32
      return 1 if cs.size < 2
      names = reader.resolve(cs.unsafe_fetch(1)).as?(PDF::Objects::Array)
      names ? names.size : 1
    end

    # Réduit la liste de filtres au filtre image significatif (le
    # dernier), traduit en libellé court.
    private def self.classify_filter(reader : PDF::Reader, filter : PDF::Objects::Base?) : String?
      return unless filter
      resolved = reader.resolve(filter)
      name = case resolved
             when PDF::Objects::Name
               resolved.value
             when PDF::Objects::Array
               # Le filtre image est le dernier de la chaîne.
               last = nil
               resolved.each { |f| last = reader.resolve(f).as?(PDF::Objects::Name).try(&.value) || last }
               last
             end
      case name
      when "DCTDecode", "DCT"      then "jpeg"
      when "JPXDecode"             then "jpx"
      when "CCITTFaxDecode", "CCF" then "ccitt"
      when "JBIG2Decode"           then "jbig2"
      when "LZWDecode", "LZW"      then "lzw"
      when "RunLengthDecode", "RL" then "rle"
      when "FlateDecode", "Fl"     then "flate"
      else                              name.try(&.downcase)
      end
    end

    # Écrit un en-tête + des octets Netpbm. Pour le PBM (1 bit), les
    # octets bruts du PDF (1 = noir inversé) sont recopiés tels quels :
    # le format P4 attend justement des bits empaquetés par ligne.
    private def write_netpbm(io : IO, format : String) : Nil
      case format
      when "ppm"
        io << "P6\n#{@width} #{@height}\n255\n"
        io.write(@stream.data)
      when "pgm"
        io << "P5\n#{@width} #{@height}\n255\n"
        io.write(@stream.data)
      when "pbm"
        io << "P4\n#{@width} #{@height}\n"
        io.write(@stream.data)
      end
    end

    private def self.int_value(reader : PDF::Reader, obj : PDF::Objects::Base?) : Int32?
      return unless obj
      reader.resolve(obj).as?(PDF::Objects::Number).try(&.to_i64.to_i)
    end

    private def self.name_value(reader : PDF::Reader, obj : PDF::Objects::Base?) : String?
      return unless obj
      reader.resolve(obj).as?(PDF::Objects::Name).try(&.value)
    end
  end
end
