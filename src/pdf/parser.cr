# Analyseur syntaxique PDF.
#
# Lit les octets bruts d'un fichier PDF et construit les objets
# correspondants (Dictionary, Array, Stream, etc.) en suivant
# la spécification ISO 32000-1:2008.
module PDF
  class Parser
    # Caractères considérés comme espacement en PDF
    WHITESPACE = Set{0x00_u8, 0x09_u8, 0x0A_u8, 0x0C_u8, 0x0D_u8, 0x20_u8}

    # Caractères délimiteurs en PDF
    DELIMITERS = Set{
      '('.ord.to_u8, ')'.ord.to_u8,
      '<'.ord.to_u8, '>'.ord.to_u8,
      '['.ord.to_u8, ']'.ord.to_u8,
      '{'.ord.to_u8, '}'.ord.to_u8,
      '/'.ord.to_u8, '%'.ord.to_u8,
    }

    # Données brutes du PDF
    getter data : Bytes

    # Table de correspondance numéro d'objet => offset en octets
    getter xref : Hash(Int32, Int64)

    # Dictionnaire trailer du PDF
    getter trailer : Objects::Dictionary

    # Version PDF extraite de l'en-tête
    getter version : String

    # Objets déjà analysés (cache)
    getter objects : Hash(Int32, Objects::Indirect)

    # Position courante dans le flux d'octets
    @pos : Int64

    # Handler de chiffrement à appliquer sur les streams et les
    # strings indirectes (nil pour PDFs non chiffrés). Configuré
    # par `Reader.initialize` après détection du `/Encrypt` dans
    # le trailer et validation du mot de passe.
    property security_handler : Encryption::StandardSecurity? = nil

    # Numéro d'objet indirect du dict `/Encrypt` (s'il existe en
    # tant qu'objet indirect plutôt que dict en ligne dans le
    # trailer). Spec § 7.6.2 : les strings du dict /Encrypt
    # ne sont JAMAIS chiffrées, donc le parser doit les laisser
    # tranquilles même quand `security_handler` est actif.
    property encrypt_object_number : Int32? = nil

    # Numéro d'objet courant en cours d'analyse — utilisé par
    # `parse_stream` pour calculer la clé par-objet quand le
    # `security_handler` est actif.
    @current_obj_num : Int32 = 0
    @current_gen : Int32 = 0

    # Repositionne le curseur de lecture (utilisé par les
    # sous-parsers d'object streams).
    def seek(offset : Int64) : Nil
      @pos = offset
    end

    def initialize(@data : Bytes)
      @pos = 0_i64
      @xref = {} of Int32 => Int64
      @trailer = Objects::Dictionary.new
      @version = ""
      @objects = {} of Int32 => Objects::Indirect
      @compressed_objects = {} of Int32 => Tuple(Int32, Int32)
    end

    # Carte des objets stockés en object stream (PDF 1.5+) :
    # `obj_num → {object_stream_num, index_in_stream}`. Peuplée par
    # `parse_xref_stream` quand des entrées de type 2 sont rencontrées.
    getter compressed_objects : Hash(Int32, Tuple(Int32, Int32))

    # Analyse la structure complète du PDF
    def parse! : Nil
      @version = parse_header
      xref_offset = find_xref_offset

      # Lire toutes les tables xref en suivant la chaîne /Prev
      # Chaque section xref est suivie de son trailer (en mode
      # classique) ; un xref stream contient les deux à la fois.
      all_sections = [] of {Hash(Int32, Int64), Hash(Int32, Tuple(Int32, Int32)), Objects::Dictionary}
      current_offset = xref_offset

      loop do
        entries, compressed, trailer = parse_xref_or_stream(current_offset)
        all_sections << {entries, compressed, trailer}

        # Suivre /Prev pour la section xref précédente
        if prev = trailer["Prev"]?
          if prev_num = prev.as?(Objects::Number)
            current_offset = prev_num.to_i64
          else
            break
          end
        else
          break
        end
      end

      # Le trailer principal est celui de la section la plus récente
      @trailer = all_sections[0][2]

      # Fusionner les tables xref (les plus anciennes d'abord, les plus récentes écrasent)
      all_sections.reverse_each do |entries, compressed, _|
        entries.each do |obj_num, offset|
          @xref[obj_num] = offset
        end
        compressed.each do |obj_num, ref|
          @compressed_objects[obj_num] = ref
        end
      end

      # Sanity check + récupération. Certains producteurs écrivent une
      # xref avec un `first_obj` incorrect ou des offsets décalés — la
      # table lit sans erreur mais pointe à côté. Preview.app, Acrobat
      # et qpdf savent reconstruire en scannant les tokens `N G obj`.
      # On fait pareil : si la xref ne colle pas, on la remplace par la
      # version reconstruite.
      unless xref_coherent?
        recovered = scan_xref_by_forward_scan
        if !recovered.empty?
          @xref = recovered
        end
      end
    end

    # Sanity check : au moins 1 offset doit pointer vers `N G obj` où
    # `N` égale le numéro de l'entrée xref. Un seul désaccord suffit à
    # déclarer la xref corrompue (cas vécu : tous décalés d'un rang).
    # Les objets en object streams (type 2) sont absents de `@xref` et
    # donc hors du check, ce qui est correct.
    private def xref_coherent? : Bool
      return true if @xref.empty?
      @xref.each do |obj_num, offset|
        return false unless object_marker_at?(offset, obj_num)
      end
      true
    end

    # Teste si à `offset` on trouve bien le motif `<obj_num> <gen> obj`
    # (gen est accepté quelconque, seul le obj_num est vérifié).
    # Robuste au séparateur de ligne (CR, LF, CRLF) et aux tabs.
    private def object_marker_at?(offset : Int64, expected_obj_num : Int32) : Bool
      return false if offset < 0 || offset >= @data.size
      saved = @pos
      begin
        @pos = offset
        skip_whitespace
        return false if @pos >= @data.size
        start = @pos
        # Lit obj_num
        return false unless @data[@pos] >= '0'.ord.to_u8 && @data[@pos] <= '9'.ord.to_u8
        obj_num = read_int
        return false unless obj_num == expected_obj_num
        skip_whitespace
        return false if @pos >= @data.size
        return false unless @data[@pos] >= '0'.ord.to_u8 && @data[@pos] <= '9'.ord.to_u8
        _gen = read_int
        skip_whitespace
        return false if @pos + 3 > @data.size
        return false unless @data[@pos] == 'o'.ord.to_u8 &&
                            @data[@pos + 1] == 'b'.ord.to_u8 &&
                            @data[@pos + 2] == 'j'.ord.to_u8
        # Vérifie que le caractère après "obj" n'est pas alphanumérique
        next_char = @pos + 3 < @data.size ? @data[@pos + 3] : 0x20_u8
        !(next_char >= 'a'.ord.to_u8 && next_char <= 'z'.ord.to_u8) &&
          !(next_char >= 'A'.ord.to_u8 && next_char <= 'Z'.ord.to_u8) &&
          !(next_char >= '0'.ord.to_u8 && next_char <= '9'.ord.to_u8)
      rescue
        false
      ensure
        @pos = saved
      end
    end

    # Reconstruit la table xref par scan forward du fichier, pattern
    # observé par les viewers robustes (Preview, Acrobat, qpdf).
    # Parcourt `@data` à la recherche du motif
    # `<EOL><obj_num> <gen> obj` au début d'une ligne (après CR, LF ou
    # CRLF, ou au tout début du fichier). Les occurrences à l'intérieur
    # d'un stream compressé (FlateDecode) sont statistiquement nulles.
    # Les objets en object streams (PDF 1.5+, entrées type 2) ne sont
    # PAS récupérés ici — ils restent dans @compressed_objects.
    private def scan_xref_by_forward_scan : Hash(Int32, Int64)
      result = {} of Int32 => Int64
      n = @data.size
      i = 0
      while i < n
        # `i` est au début d'une ligne : i=0 ou le précédent est \r/\n
        line_start = i == 0 || @data[i - 1] == 0x0A_u8 || @data[i - 1] == 0x0D_u8
        if line_start
          saved = @pos
          begin
            @pos = i.to_i64
            # obj_num doit être entre 1 et un million
            if @pos < n && @data[@pos] >= '0'.ord.to_u8 && @data[@pos] <= '9'.ord.to_u8
              obj_start = @pos
              obj_num = read_int
              if obj_num >= 1 && obj_num < 1_000_000 && @pos < n &&
                 (@data[@pos] == 0x20_u8 || @data[@pos] == 0x09_u8)
                skip_whitespace
                if @pos < n && @data[@pos] >= '0'.ord.to_u8 && @data[@pos] <= '9'.ord.to_u8
                  _gen = read_int
                  skip_whitespace
                  if @pos + 3 <= n &&
                     @data[@pos] == 'o'.ord.to_u8 &&
                     @data[@pos + 1] == 'b'.ord.to_u8 &&
                     @data[@pos + 2] == 'j'.ord.to_u8
                    next_char = @pos + 3 < n ? @data[@pos + 3] : 0x20_u8
                    is_word_boundary = !(next_char >= 'a'.ord.to_u8 && next_char <= 'z'.ord.to_u8) &&
                                       !(next_char >= 'A'.ord.to_u8 && next_char <= 'Z'.ord.to_u8) &&
                                       !(next_char >= '0'.ord.to_u8 && next_char <= '9'.ord.to_u8)
                    if is_word_boundary
                      # Garde la dernière occurrence (révisions
                      # incrémentales possibles).
                      result[obj_num] = obj_start
                    end
                  end
                end
              end
            end
          rescue
            # Chiffre trop grand, EOF, etc. — skip et continue.
          ensure
            @pos = saved
          end
        end
        i += 1
      end
      result
    end

    # Décide si l'offset pointe sur un xref classique (token "xref")
    # ou sur un xref stream (objet indirect avec /Type /XRef). Renvoie
    # `{xref_entries, compressed_entries, trailer}`.
    private def parse_xref_or_stream(offset : Int64) : Tuple(Hash(Int32, Int64), Hash(Int32, Tuple(Int32, Int32)), Objects::Dictionary)
      @pos = offset
      skip_whitespace
      token = peek_token
      if token == "xref"
        # Format classique
        entries = parse_xref(offset)
        skip_whitespace
        trailer = parse_trailer
        {entries, {} of Int32 => Tuple(Int32, Int32), trailer}
      else
        # Xref stream PDF 1.5+ : c'est un objet indirect "N M obj
        # <<...>> stream ... endstream endobj"
        parse_xref_stream(offset)
      end
    end

    # Analyse un objet indirect à la position donnée
    def parse_object_at(offset : Int64) : Objects::Indirect
      @pos = offset
      obj_num = read_int
      skip_whitespace
      gen_num = read_int
      skip_whitespace
      expect_token("obj")
      skip_whitespace
      # Mémoriser le couple (obj_num, gen) pour que `parse_stream`
      # puisse calculer la clé par-objet quand un `security_handler`
      # est configuré.
      saved_obj, saved_gen = @current_obj_num, @current_gen
      @current_obj_num, @current_gen = obj_num, gen_num
      begin
        value = parse_value
      ensure
        @current_obj_num, @current_gen = saved_obj, saved_gen
      end
      skip_whitespace
      # endobj peut être absent si c'est un stream (déjà lu dans parse_value)
      if @pos < @data.size
        token = peek_token
        if token == "endobj"
          read_token
        end
      end

      # Déchiffrer récursivement les strings dans le sous-arbre.
      # Les streams sont déjà déchiffrés dans `parse_stream`, mais
      # les strings (ex. /Title du /Info, /Producer, etc.) sont
      # parsées ici en clair tant qu'on ne déchiffre pas. On le fait
      # APRÈS coup en marchant le sous-arbre.
      #
      # Exception spec § 7.6.2 : le dict `/Encrypt` lui-même contient
      # des strings (/O, /U, /OE, /UE, /Perms) qui ne SONT PAS chiffrées —
      # leurs bytes ont leur propre sémantique (hash, blob AES indépendant).
      # On saute donc le déchiffrement quand on parse l'objet /Encrypt.
      if (sh = @security_handler) &&
         !value.is_a?(Objects::Stream) &&
         obj_num != @encrypt_object_number
        decrypt_strings_in_place(value, obj_num, gen_num, sh)
      end

      Objects::Indirect.new(obj_num, gen_num, value)
    end

    # Marche récursivement la valeur et déchiffre toutes les
    # `Objects::Str` rencontrées (sauf celles internes à un /Encrypt
    # ou un /XRef stream — pas vraiment de risque ici car on travaille
    # uniquement sur le sous-arbre d'un objet indirect non-stream).
    private def decrypt_strings_in_place(
      obj : Objects::Base,
      obj_num : Int32,
      gen : Int32,
      sh : Encryption::StandardSecurity,
    ) : Nil
      case obj
      when Objects::Str
        # Déchiffre en place : remplace `value` par le plaintext.
        decrypted = sh.decrypt_object(obj.value.to_slice, obj_num, gen)
        obj.value = String.new(decrypted)
      when Objects::Dictionary
        obj.values.each do |v|
          decrypt_strings_in_place(v, obj_num, gen, sh)
        end
      when Objects::Array
        obj.each do |v|
          decrypt_strings_in_place(v, obj_num, gen, sh)
        end
      end
      # Number, Name, Boolean, Null, Reference : rien à faire.
    end

    # Analyse une valeur PDF quelconque à la position courante
    def parse_value : Objects::Base
      skip_whitespace
      return Objects::Null.instance if @pos >= @data.size

      byte = peek_byte

      case byte
      when '<'.ord.to_u8
        # Dictionnaire << >> ou chaîne hexadécimale < >
        if @pos + 1 < @data.size && @data[@pos + 1] == '<'.ord.to_u8
          parse_dictionary
        else
          parse_hex_string
        end
      when '('.ord.to_u8
        parse_string
      when '['.ord.to_u8
        parse_array
      when '/'.ord.to_u8
        parse_name
      when '+'.ord.to_u8, '-'.ord.to_u8, '.'.ord.to_u8
        parse_number
      else
        if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
          # Peut être un nombre ou une référence (N M R)
          parse_number_or_reference
        else
          # Mot-clé : true, false, null
          token = read_token
          case token
          when "true"
            Objects::Boolean.new(true)
          when "false"
            Objects::Boolean.new(false)
          when "null"
            Objects::Null.instance
          else
            # Valeur inattendue, on retourne null
            Objects::Null.instance
          end
        end
      end
    end

    # Analyse un dictionnaire PDF << ... >>
    # Peut retourner un Stream si le dictionnaire est suivi de "stream"
    def parse_dictionary : Objects::Base
      expect_bytes("<<")
      dict = Objects::Dictionary.new

      loop do
        skip_whitespace
        break if @pos >= @data.size

        # Vérifier la fin du dictionnaire
        if peek_byte == '>'.ord.to_u8 && @pos + 1 < @data.size && @data[@pos + 1] == '>'.ord.to_u8
          @pos += 2
          break
        end

        # Clé (doit être un Name)
        key = parse_name
        skip_whitespace

        # Valeur
        value = parse_value
        dict[key] = value
      end

      # Vérifier si un stream suit le dictionnaire
      skip_whitespace
      if @pos + 6 <= @data.size
        maybe_stream = String.new(@data[@pos, 6])
        if maybe_stream == "stream"
          return parse_stream(dict)
        end
      end

      dict
    end

    # Analyse un stream PDF (appelé après le dictionnaire)
    def parse_stream(dict : Objects::Dictionary) : Objects::Stream
      expect_token("stream")

      # Sauter le retour à la ligne après "stream"
      # La spécification dit : CR, LF, ou CR+LF
      if @pos < @data.size && @data[@pos] == 0x0D_u8
        @pos += 1
      end
      if @pos < @data.size && @data[@pos] == 0x0A_u8
        @pos += 1
      end

      # Lire la longueur depuis le dictionnaire
      length = 0_i64
      if len_obj = dict["Length"]?
        case len_obj
        when Objects::Number
          length = len_obj.to_i64
        when Objects::Reference
          # Résoudre la référence indirecte pour récupérer la
          # longueur. Deux chemins possibles :
          # * objet uncompressed (offset dans @xref)
          # * objet compressé (PDF 1.5+, dans un object stream)
          # `parse_object_at` et `resolve_compressed_object` modifient
          # `@pos`, on encadre donc l'appel d'un save/restore.
          saved_pos = @pos
          length_value =
            if offset = @xref[len_obj.object_number]?
              parse_object_at(offset).value
            elsif (compressed = resolve_compressed_object(len_obj.object_number))
              compressed.value
            end
          @pos = saved_pos
          if num = length_value.try(&.as?(Objects::Number))
            length = num.to_i64
          end
        end
      end

      # Extraire les données brutes du stream
      stream_data = if length > 0 && (@pos + length) <= @data.size
                      @data[@pos, length]
                    else
                      Bytes.empty
                    end
      @pos += length

      # Sauter jusqu'à endstream
      skip_whitespace
      if @pos + 9 <= @data.size
        token = peek_token
        if token == "endstream"
          read_token
        end
      end

      # Déchiffrer si un Security Handler est configuré. Le
      # déchiffrement intervient AVANT la décompression : le PDF
      # spec applique d'abord les filtres /Filter (Flate, etc.)
      # puis le « Crypt » au-dessus, donc à la lecture on inverse :
      # déchiffrement → décompression.
      if sh = @security_handler
        # Pas de déchiffrement pour le stream du Metadata si
        # /EncryptMetadata est false (PDF 1.5+) — non géré dans
        # cette première version, on déchiffre tout.
        stream_data = sh.decrypt_object(stream_data, @current_obj_num, @current_gen)
      end

      # Décompresser si possible. Si un filtre n'est pas supporté
      # (CCITTFaxDecode, DCTDecode, JBIG2Decode, JPXDecode, …),
      # on conserve les octets bruts ENCODÉS et on marque le stream
      # comme non décodé pour que le merger / writer sache préserver
      # `/Filter` et `/DecodeParms` à la ré-écriture.
      decoded_data, was_decoded = decompress_stream(dict, stream_data)

      Objects::Stream.new(dict, decoded_data, was_decoded)
    end

    # Analyse un tableau PDF [ ... ]
    def parse_array : Objects::Array
      @pos += 1 # Sauter '['
      arr = Objects::Array.new

      loop do
        skip_whitespace
        break if @pos >= @data.size
        break if peek_byte == ']'.ord.to_u8

        arr << parse_value
      end

      @pos += 1 if @pos < @data.size # Sauter ']'
      arr
    end

    # Analyse une chaîne littérale PDF ( ... )
    def parse_string : Objects::Str
      @pos += 1 # Sauter '('
      result = IO::Memory.new
      depth = 1

      while @pos < @data.size && depth > 0
        byte = read_byte
        case byte
        when '('.ord.to_u8
          depth += 1
          result.write_byte(byte)
        when ')'.ord.to_u8
          depth -= 1
          result.write_byte(byte) if depth > 0
        when '\\'.ord.to_u8
          # Séquence d'échappement
          if @pos < @data.size
            next_byte = read_byte
            case next_byte
            when 'n'.ord.to_u8  then result.write_byte(0x0A_u8)
            when 'r'.ord.to_u8  then result.write_byte(0x0D_u8)
            when 't'.ord.to_u8  then result.write_byte(0x09_u8)
            when 'b'.ord.to_u8  then result.write_byte(0x08_u8)
            when 'f'.ord.to_u8  then result.write_byte(0x0C_u8)
            when '('.ord.to_u8  then result.write_byte('('.ord.to_u8)
            when ')'.ord.to_u8  then result.write_byte(')'.ord.to_u8)
            when '\\'.ord.to_u8 then result.write_byte('\\'.ord.to_u8)
            else
              if next_byte >= '0'.ord.to_u8 && next_byte <= '7'.ord.to_u8
                # Code octal (\ddd)
                octal = String.new(Bytes[next_byte])
                2.times do
                  if @pos < @data.size
                    b = peek_byte
                    if b >= '0'.ord.to_u8 && b <= '7'.ord.to_u8
                      octal += b.chr
                      @pos += 1
                    else
                      break
                    end
                  end
                end
                result.write_byte(octal.to_u8(8))
              else
                # Caractère d'échappement inconnu, on l'ignore
                result.write_byte(next_byte)
              end
            end
          end
        else
          result.write_byte(byte)
        end
      end

      Objects::Str.new(String.new(result.to_slice))
    end

    # Analyse une chaîne hexadécimale PDF < ... >
    def parse_hex_string : Objects::Str
      @pos += 1 # Sauter '<'
      hex = String.build do |io|
        while @pos < @data.size
          byte = peek_byte
          if byte == '>'.ord.to_u8
            @pos += 1
            break
          end
          if WHITESPACE.includes?(byte)
            @pos += 1
            next
          end
          io << byte.chr
          @pos += 1
        end
      end

      # Compléter avec un 0 si longueur impaire
      hex += "0" if hex.size.odd?

      # Convertir les paires hexadécimales en octets
      bytes = IO::Memory.new
      (0...hex.size).step(2) do |i|
        pair = hex[i, 2]
        bytes.write_byte(pair.to_u8(16))
      end

      Objects::Str.new(String.new(bytes.to_slice), hex: true)
    end

    # Analyse un nom PDF /Name
    def parse_name : Objects::Name
      @pos += 1 # Sauter '/'
      name = String.build do |io|
        while @pos < @data.size
          byte = peek_byte
          break if WHITESPACE.includes?(byte) || DELIMITERS.includes?(byte)

          if byte == '#'.ord.to_u8
            # Échappement hexadécimal #XX
            @pos += 1
            if @pos + 1 < @data.size
              hex = String.new(@data[@pos, 2])
              io << hex.to_u8(16).chr
              @pos += 2
            end
          else
            io << byte.chr
            @pos += 1
          end
        end
      end

      Objects::Name.new(name)
    end

    # Analyse un nombre PDF (entier ou réel)
    def parse_number : Objects::Number
      token = read_number_token
      if token.includes?('.')
        Objects::Number.new(token.to_f64)
      else
        Objects::Number.new(token.to_i64)
      end
    end

    # Analyse un nombre ou une référence indirecte (N M R)
    private def parse_number_or_reference : Objects::Base
      saved_pos = @pos
      token1 = read_number_token
      is_int1 = !token1.includes?('.')

      if is_int1
        saved_pos2 = @pos
        skip_whitespace
        if @pos < @data.size && peek_byte >= '0'.ord.to_u8 && peek_byte <= '9'.ord.to_u8
          token2 = read_number_token
          is_int2 = !token2.includes?('.')
          if is_int2
            skip_whitespace
            if @pos < @data.size && peek_byte == 'R'.ord.to_u8
              @pos += 1
              obj_num = token1.to_i32
              gen_num = token2.to_i32
              return Objects::Reference.new(obj_num, gen_num)
            end
          end
        end
        # Pas une référence, revenir à la position après le premier nombre
        @pos = saved_pos2
      end

      if token1.includes?('.')
        Objects::Number.new(token1.to_f64)
      else
        Objects::Number.new(token1.to_i64)
      end
    end

    # Analyse l'en-tête %PDF-X.Y
    private def parse_header : String
      @pos = 0
      line = read_line
      if line.starts_with?("%PDF-")
        line[5..]
      else
        "1.7"
      end
    end

    # Cherche l'offset de la table xref en partant de la fin.
    #
    # NOTE : la recherche est faite **au niveau octet**, sans passer
    # par `String#rindex`. Un PDF amendé par mise à jour incrémentale
    # (PDF spec § 7.5.6) contient typiquement un content stream
    # FlateDecode juste avant le second `startxref` ; ces octets
    # binaires (≥ 0x80) forment souvent des séquences UTF-8
    # multi-octets qui décalent les indices retournés par
    # `String#rindex` (qui compte des caractères, pas des octets).
    # Le résultat : `@pos = search_start + idx + 9` tombait à côté
    # et `read_int` lisait une chaîne vide → `Invalid Int32 ""`.
    def find_xref_offset : Int64
      # Chercher "startxref" dans les 1024 derniers octets, en
      # parcourant les octets en arrière depuis la fin du fichier.
      needle = "startxref".to_slice
      search_start = {0_i64, @data.size.to_i64 - 1024}.max
      idx = byte_rindex(@data, needle, search_start)
      raise "Table xref introuvable" unless idx

      # Se positionner juste après "startxref"
      @pos = idx + needle.size
      skip_whitespace
      read_int.to_i64
    end

    # Cherche la dernière occurrence de `needle` dans `haystack`,
    # à partir de l'offset `from` inclus. Retourne `nil` si absente.
    # Comparaison purement octet-à-octet — n'utilise pas la sémantique
    # de String / d'UTF-8 (cf. `find_xref_offset` pour le pourquoi).
    private def byte_rindex(haystack : Bytes, needle : Bytes, from : Int64) : Int64?
      return if needle.size == 0 || needle.size > haystack.size - from
      i = haystack.size.to_i64 - needle.size
      while i >= from
        match = true
        j = 0
        while j < needle.size
          if haystack[i + j] != needle[j]
            match = false
            break
          end
          j += 1
        end
        return i if match
        i -= 1
      end
      nil
    end

    # Analyse la table xref traditionnelle
    def parse_xref(offset : Int64) : Hash(Int32, Int64)
      @pos = offset
      result = {} of Int32 => Int64
      expect_token("xref")

      # Lire les sous-sections
      loop do
        skip_whitespace
        break if @pos >= @data.size

        # Vérifier si c'est le début du trailer
        if peek_byte == 't'.ord.to_u8
          break
        end

        # Lire le numéro de départ et le nombre d'entrées
        first_obj = read_int
        skip_whitespace
        count = read_int
        skip_whitespace

        count.times do |i|
          obj_num = first_obj + i
          entry_offset = read_int.to_i64
          skip_whitespace
          _gen = read_int
          skip_whitespace
          flag = read_byte.chr
          skip_whitespace

          # 'n' = en usage, 'f' = libre
          if flag == 'n' && entry_offset > 0
            result[obj_num] = entry_offset
          end
        end
      end

      result
    end

    # Analyse un xref stream PDF 1.5+ (ISO 32000-1 § 7.5.8).
    #
    # Un xref stream est un objet indirect dont le dictionnaire
    # contient les mêmes clés qu'un trailer (`/Root`, `/Info`,
    # `/Size`, `/Prev`, `/ID`) plus :
    # * `/Type /XRef`
    # * `/W [w1 w2 w3]` — largeurs des champs des entrées (octets)
    # * `/Index [first1 count1 first2 count2 …]` — sous-sections
    #   d'objets représentées (par défaut `[0 Size]`)
    #
    # Le stream lui-même contient `Σ count` entrées de `w1+w2+w3`
    # octets, encodées en gros-boutiste, généralement compressées
    # par FlateDecode + Predictor PNG.
    #
    # Type d'entrée selon `field1` (largeur `w1`) :
    # * 0 — objet libre (chaîne libre)
    # * 1 — objet en usage (`field2`=offset, `field3`=génération)
    # * 2 — objet en object stream (`field2`=numéro objstm,
    #       `field3`=index dans l'objstm)
    private def parse_xref_stream(offset : Int64) : Tuple(Hash(Int32, Int64), Hash(Int32, Tuple(Int32, Int32)), Objects::Dictionary)
      indirect = parse_object_at(offset)
      stream = indirect.value.as?(Objects::Stream)
      raise "Xref stream attendu à l'offset #{offset}" unless stream
      dict = stream.dictionary

      # /W : largeurs des champs
      w_arr = dict["W"]?.as?(Objects::Array)
      raise "Xref stream sans /W" unless w_arr
      w = w_arr.compact_map(&.as?(Objects::Number)).map { |n| n.to_i64.to_i32 }
      raise "Xref stream /W invalide" if w.size != 3
      w1, w2, w3 = w[0], w[1], w[2]
      entry_size = w1 + w2 + w3

      # /Index : sous-sections (par défaut [0, Size])
      sections = [] of Tuple(Int32, Int32)
      if idx_arr = dict["Index"]?.as?(Objects::Array)
        nums = idx_arr.compact_map(&.as?(Objects::Number)).map { |n| n.to_i64.to_i32 }
        (0...nums.size).step(2) do |i|
          sections << {nums[i], nums[i + 1]}
        end
      else
        size = dict["Size"]?.try(&.as?(Objects::Number)).try(&.to_i64).try(&.to_i32) || 0
        sections << {0, size}
      end

      data = stream.data
      entries = {} of Int32 => Int64
      compressed = {} of Int32 => Tuple(Int32, Int32)
      cursor = 0

      sections.each do |first, count|
        count.times do |i|
          obj_num = first + i
          field1 = w1 == 0 ? 1_i64 : read_be_int(data, cursor, w1)
          field2 = w2 == 0 ? 0_i64 : read_be_int(data, cursor + w1, w2)
          field3 = w3 == 0 ? 0_i64 : read_be_int(data, cursor + w1 + w2, w3)
          cursor += entry_size

          case field1
          when 0_i64
            # libre — ignore
          when 1_i64
            # en usage classique
            entries[obj_num] = field2
          when 2_i64
            # objet compressé dans un object stream
            compressed[obj_num] = {field2.to_i32, field3.to_i32}
          end
        end
      end

      # Le dictionnaire du xref stream sert aussi de trailer.
      {entries, compressed, dict}
    end

    # Lit un entier gros-boutiste de `width` octets dans `data` à
    # partir de `offset`. Largeur 0 = valeur par défaut (1 pour le
    # type, 0 sinon — géré par l'appelant).
    private def read_be_int(data : Bytes, offset : Int32, width : Int32) : Int64
      result = 0_i64
      width.times do |i|
        result = (result << 8) | data[offset + i].to_i64
      end
      result
    end

    # Résout un objet stocké dans un object stream (PDF 1.5+,
    # ISO 32000-1 § 7.5.7).
    #
    # Un object stream est un objet indirect avec `/Type /ObjStm`,
    # `/N` (nb d'objets), `/First` (offset du premier objet dans les
    # données décodées). Les premières `N×2` valeurs en tête sont des
    # paires `obj_num offset_in_stream` ; suivent les valeurs des
    # objets, en clair.
    def resolve_compressed_object(obj_num : Int32) : Objects::Indirect?
      ref = @compressed_objects[obj_num]?
      return unless ref
      objstm_num, index = ref

      # Charger l'object stream s'il n'est pas déjà en cache
      objstm_indirect = @objects[objstm_num]?
      unless objstm_indirect
        offset = @xref[objstm_num]?
        return unless offset
        objstm_indirect = parse_object_at(offset)
        @objects[objstm_num] = objstm_indirect
      end

      stream = objstm_indirect.value.as?(Objects::Stream)
      return unless stream
      dict = stream.dictionary
      n = dict["N"]?.try(&.as?(Objects::Number)).try(&.to_i64).try(&.to_i32) || 0
      first = dict["First"]?.try(&.as?(Objects::Number)).try(&.to_i64).try(&.to_i32) || 0

      # Parser les paires (obj_num, offset) en tête puis le N-ième objet
      sub_parser = Parser.new(stream.data)
      sub_parser.skip_whitespace

      pairs = [] of Tuple(Int32, Int32)
      n.times do
        num = sub_parser.read_token.to_i32
        sub_parser.skip_whitespace
        off = sub_parser.read_token.to_i32
        sub_parser.skip_whitespace
        pairs << {num, off}
      end

      return if index < 0 || index >= pairs.size
      target_num, target_offset = pairs[index]
      sub_parser.seek((first + target_offset).to_i64)
      value = sub_parser.parse_value
      Objects::Indirect.new(target_num, 0, value)
    end

    # Analyse le dictionnaire trailer
    private def parse_trailer : Objects::Dictionary
      expect_token("trailer")
      skip_whitespace
      result = parse_dictionary
      if dict = result.as?(Objects::Dictionary)
        dict
      else
        raise "Trailer invalide : dictionnaire attendu"
      end
    end

    # Saute les caractères d'espacement
    def skip_whitespace : Nil
      while @pos < @data.size
        byte = @data[@pos]
        if WHITESPACE.includes?(byte)
          @pos += 1
        elsif byte == '%'.ord.to_u8
          skip_comment
        else
          break
        end
      end
    end

    # Saute un commentaire (% jusqu'à fin de ligne)
    private def skip_comment : Nil
      while @pos < @data.size
        byte = @data[@pos]
        @pos += 1
        break if byte == 0x0A_u8 || byte == 0x0D_u8
      end
    end

    # Lit l'octet courant sans avancer
    def peek_byte : UInt8
      @data[@pos]
    end

    # Lit l'octet courant et avance
    def read_byte : UInt8
      byte = @data[@pos]
      @pos += 1
      byte
    end

    # Lit un jeton (séquence de caractères non-espace/non-délimiteur)
    def read_token : String
      skip_whitespace
      start = @pos
      while @pos < @data.size
        byte = @data[@pos]
        break if WHITESPACE.includes?(byte) || DELIMITERS.includes?(byte)
        @pos += 1
      end
      String.new(@data[start, @pos - start])
    end

    # Lit un jeton sans le consommer
    private def peek_token : String
      saved = @pos
      token = read_token
      @pos = saved
      token
    end

    # Lit un entier
    private def read_int : Int32
      skip_whitespace
      token = String.build do |io|
        while @pos < @data.size
          byte = @data[@pos]
          if (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) || byte == '+'.ord.to_u8 || byte == '-'.ord.to_u8
            io << byte.chr
            @pos += 1
          else
            break
          end
        end
      end
      token.to_i32
    end

    # Lit un jeton numérique (entier ou réel)
    private def read_number_token : String
      String.build do |io|
        while @pos < @data.size
          byte = @data[@pos]
          if (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) ||
             byte == '.'.ord.to_u8 || byte == '+'.ord.to_u8 || byte == '-'.ord.to_u8
            io << byte.chr
            @pos += 1
          else
            break
          end
        end
      end
    end

    # Lit une ligne complète
    private def read_line : String
      start = @pos
      while @pos < @data.size
        byte = @data[@pos]
        if byte == 0x0A_u8 || byte == 0x0D_u8
          line = String.new(@data[start, @pos - start])
          @pos += 1
          # Sauter CR+LF
          if @pos < @data.size && @data[@pos] == 0x0A_u8 && byte == 0x0D_u8
            @pos += 1
          end
          return line
        end
        @pos += 1
      end
      String.new(@data[start, @pos - start])
    end

    # Vérifie et consomme un jeton attendu
    private def expect_token(expected : String) : Nil
      skip_whitespace
      token = read_token
      if token != expected
        raise "Jeton attendu '#{expected}', trouvé '#{token}' à la position #{@pos}"
      end
    end

    # Vérifie et consomme une séquence d'octets attendue
    private def expect_bytes(expected : String) : Nil
      skip_whitespace
      expected.each_byte do |b|
        if @pos < @data.size && @data[@pos] == b
          @pos += 1
        else
          raise "Octets attendus '#{expected}' à la position #{@pos}"
        end
      end
    end

    # Décompresse les données d'un stream selon ses filtres.
    #
    # Renvoie `{octets, decoded?}` :
    # * `decoded? == true`  → tous les filtres ont été inversés ;
    #   `octets` contient le contenu clair.
    # * `decoded? == false` → un filtre au moins n'est pas supporté
    #   (CCITTFaxDecode, DCTDecode, JBIG2Decode, JPXDecode…) ; on
    #   préserve les octets ENCODÉS pour que le merger puisse les
    #   recopier intacts dans le PDF de sortie en gardant `/Filter`.
    private def decompress_stream(dict : Objects::Dictionary, data : Bytes) : Tuple(Bytes, Bool)
      filter = dict["Filter"]?
      return {data, true} unless filter

      filter_names = case filter
                     when Objects::Name
                       [filter.value]
                     when Objects::Array
                       filter.compact_map(&.as?(Objects::Name)).map(&.value)
                     else
                       [] of String
                     end

      result = data
      filter_names.each do |name|
        decoded, ok = apply_filter(name, result, dict)
        return {data, false} unless ok
        result = decoded
      end
      {result, true}
    end

    # Applique un filtre. Renvoie `{octets, success?}`. `success? == false`
    # signale un filtre non supporté ; le caller doit alors conserver les
    # données brutes encodées et marquer le stream comme non décodé.
    private def apply_filter(name : String, data : Bytes, dict : Objects::Dictionary) : Tuple(Bytes, Bool)
      case name
      when "FlateDecode", "Fl"
        decoded = Filters::Flate.new.decode(data)
        # Predictor PNG (utilisé surtout par les xref streams)
        if parms = dict["DecodeParms"]?
          if pdict = parms.as?(Objects::Dictionary)
            predictor = pdict["Predictor"]?.try(&.as?(Objects::Number)).try(&.to_i64).try(&.to_i32) || 1
            if predictor >= 10
              columns = pdict["Columns"]?.try(&.as?(Objects::Number)).try(&.to_i64).try(&.to_i32) || 1
              decoded = apply_png_predictor(decoded, columns)
            end
          end
        end
        {decoded, true}
      when "ASCIIHexDecode", "AHx"
        {ascii_hex_decode(data), true}
      when "ASCII85Decode", "A85"
        {ascii85_decode(data), true}
      else
        # Filtres non supportés : DCTDecode (JPEG), CCITTFaxDecode,
        # JBIG2Decode, JPXDecode, LZWDecode, RunLengthDecode, Crypt.
        # Données conservées encodées ; le drapeau `decoded` du Stream
        # passera à `false`.
        {data, false}
      end
    end

    # Inverse le filtre de prédiction PNG (utilisé avec FlateDecode
    # par les xref streams et certaines images). Le PDF inclut un
    # octet de "tag" en tête de chaque ligne indiquant l'algorithme :
    #   0 = None, 1 = Sub, 2 = Up, 3 = Average, 4 = Paeth.
    # Pour les xref streams le predictor le plus courant est `Up` (12).
    private def apply_png_predictor(data : Bytes, columns : Int32) : Bytes
      row_size = columns + 1 # +1 pour le tag d'algorithme
      return data if row_size <= 1 || data.size % row_size != 0
      rows = data.size // row_size
      result = Bytes.new(rows * columns)
      prev_row = Bytes.new(columns)

      rows.times do |r|
        tag = data[r * row_size]
        line = data[r * row_size + 1, columns]
        out_line = Bytes.new(columns)
        case tag
        when 0_u8 # None
          line.copy_to(out_line)
        when 1_u8 # Sub
          columns.times do |c|
            left = c >= 1 ? out_line[c - 1] : 0_u8
            out_line[c] = (line[c] &+ left).to_u8
          end
        when 2_u8 # Up
          columns.times do |c|
            out_line[c] = (line[c] &+ prev_row[c]).to_u8
          end
        when 3_u8 # Average
          columns.times do |c|
            left = c >= 1 ? out_line[c - 1] : 0_u8
            up = prev_row[c]
            avg = ((left.to_i32 + up.to_i32) // 2).to_u8
            out_line[c] = (line[c] &+ avg).to_u8
          end
        when 4_u8 # Paeth
          columns.times do |c|
            a = c >= 1 ? out_line[c - 1].to_i32 : 0
            b = prev_row[c].to_i32
            cc = c >= 1 ? prev_row[c - 1].to_i32 : 0
            p = a + b - cc
            pa = (p - a).abs
            pb = (p - b).abs
            pc = (p - cc).abs
            paeth = if pa <= pb && pa <= pc
                      a
                    elsif pb <= pc
                      b
                    else
                      cc
                    end
            out_line[c] = (line[c] &+ paeth.to_u8).to_u8
          end
        else
          line.copy_to(out_line)
        end
        out_line.copy_to(result + r * columns)
        prev_row = out_line
      end
      result
    end

    # ASCIIHex : chaque paire de chiffres hexa = un octet. Termine
    # à `>` (sentinelle PDF) ; ignore les blancs.
    private def ascii_hex_decode(data : Bytes) : Bytes
      result = IO::Memory.new
      hex = String.build do |io|
        data.each do |b|
          break if b == '>'.ord.to_u8
          next if WHITESPACE.includes?(b)
          io << b.chr
        end
      end
      hex += "0" if hex.size.odd?
      (0...hex.size).step(2) do |i|
        result.write_byte(hex[i, 2].to_u8(16))
      end
      result.to_slice
    end

    # ASCII85 : 5 caractères ASCII = 4 octets (base 85). `~>` termine.
    private def ascii85_decode(data : Bytes) : Bytes
      result = IO::Memory.new
      buffer = [] of UInt32
      i = 0
      while i < data.size
        b = data[i]
        i += 1
        break if b == '~'.ord.to_u8
        next if WHITESPACE.includes?(b)
        if b == 'z'.ord.to_u8 && buffer.empty?
          4.times { result.write_byte(0_u8) }
          next
        end
        next if b < '!'.ord.to_u8 || b > 'u'.ord.to_u8
        buffer << (b - '!'.ord.to_u8).to_u32
        if buffer.size == 5
          v = 0_u32
          buffer.each { |x| v = v * 85 + x }
          result.write_byte(((v >> 24) & 0xff).to_u8)
          result.write_byte(((v >> 16) & 0xff).to_u8)
          result.write_byte(((v >> 8) & 0xff).to_u8)
          result.write_byte((v & 0xff).to_u8)
          buffer.clear
        end
      end
      unless buffer.empty?
        # Padding : le dernier groupe peut être partiel
        partial = buffer.size
        until buffer.size == 5
          buffer << 84_u32 # max digit pour padding
        end
        v = 0_u32
        buffer.each { |x| v = v * 85 + x }
        bytes_to_write = partial - 1
        result.write_byte(((v >> 24) & 0xff).to_u8) if bytes_to_write >= 1
        result.write_byte(((v >> 16) & 0xff).to_u8) if bytes_to_write >= 2
        result.write_byte(((v >> 8) & 0xff).to_u8) if bytes_to_write >= 3
      end
      result.to_slice
    end
  end
end
