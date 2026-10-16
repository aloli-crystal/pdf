module PDF
  module Writer
    # Writes a complete PDF document to an IO.
    #
    # The writer handles:
    # - PDF header and version
    # - Binary marker (for proper binary handling)
    # - All indirect objects
    # - Cross-reference table
    # - Trailer dictionary
    # - EOF marker
    # - Encryption (when configured via `Document#encrypt`)
    class DocumentWriter
      # The document being written
      getter document : Document

      # Object byte offsets for xref table (regular indirect objects).
      @offsets : Hash(Int32, Int64)

      # When object_streams are enabled, this hash maps a compressed
      # object number to {ObjStm container number, index in ObjStm}.
      # Used by `build_xref_indirect` to emit type-2 entries.
      @compressed : Hash(Int32, Tuple(Int32, Int32))

      def initialize(@document : Document)
        @offsets = {} of Int32 => Int64
        @compressed = {} of Int32 => Tuple(Int32, Int32)
      end

      # Writes the complete PDF to the given IO.
      def write(io : IO) : Nil
        # Finalize the document (creates all objects)
        @document.finalize!

        # Register info dictionary BEFORE writing objects so it's in the xref
        info_ref = if info = @document.info_dict
                     @document.register_object(info).reference
                   end

        # Si chiffrement activé, enregistrer le dict /Encrypt et
        # chiffrer les objets AVANT sérialisation.
        encrypt_obj_num = nil
        if handler = @document.security_handler
          enc_dict = handler.to_encrypt_dict
          enc_obj = @document.register_object(enc_dict)
          encrypt_obj_num = enc_obj.object_number
          encrypt_objects(handler, encrypt_obj_num)
        end

        # Track current position
        position = 0_i64

        # Write header
        header = write_header
        io << header
        position += header.bytesize

        # Object streams (PDF spec § 7.5.7) : group compressible
        # indirect objects (dict, array, number, string, name, bool,
        # null) into a single `/Type /ObjStm`. Streams stay
        # standalone. Only runs if `object_streams?` is true ; the
        # mode also forces `xref_format = :stream` upstream.
        objstm_indirect = nil
        if @document.object_streams?
          objstm_indirect = build_object_stream
        end

        # Write all objects. If `objstm_indirect` is set, skip the
        # objects that ended up inside it (they're now referenced
        # via type-2 xref entries).
        compressible = @compressed.keys.to_set
        @document.objects.each do |obj|
          next if compressible.includes?(obj.object_number)
          @offsets[obj.object_number] = position
          content = obj.to_pdf + "\n"
          io << content
          position += content.bytesize
        end

        # Write the ObjStm itself (if any) as a regular indirect.
        if oi = objstm_indirect
          @offsets[oi.object_number] = position
          content = oi.to_pdf + "\n"
          io << content
          position += content.bytesize
        end

        xref_start = position

        case @document.xref_format
        when :stream
          # Cross-reference stream (PDF 1.5+) — embeds the trailer.
          xref_num = @document.allocate_object_id
          @offsets[xref_num] = xref_start
          xref_indirect = build_xref_indirect(xref_num, info_ref, encrypt_obj_num)
          io << xref_indirect.to_pdf << "\n"
          io << "startxref\n" << xref_start << "\n%%EOF\n"
        else
          # Classic xref table + trailer.
          xref = write_xref
          io << xref
          io << write_trailer(xref_start, info_ref, encrypt_obj_num)
        end
      end

      # Chiffre tous les streams et toutes les strings indirectes
      # (sauf le dict /Encrypt lui-même) avec le handler fourni.
      private def encrypt_objects(
        handler : Encryption::StandardSecurity,
        encrypt_obj_num : Int32,
      ) : Nil
        @document.objects.each do |indirect|
          next if indirect.object_number == encrypt_obj_num
          encrypt_in_place(
            indirect.value,
            indirect.object_number,
            indirect.generation,
            handler,
          )
        end
      end

      # Marche récursivement le sous-arbre d'un objet indirect et
      # chiffre les `Stream` et `Str` rencontrés. Pour les streams,
      # on chiffre les octets ENCODÉS (post-Filter Flate) puisque le
      # spec applique le crypt filter au-dessus des autres filtres.
      private def encrypt_in_place(
        obj : Objects::Base,
        obj_num : Int32,
        gen : Int32,
        handler : Encryption::StandardSecurity,
      ) : Nil
        case obj
        when Objects::Stream
          encrypt_stream(obj, obj_num, gen, handler)
        when Objects::Str
          encrypt_string(obj, obj_num, gen, handler)
        when Objects::Dictionary
          obj.values.each { |v| encrypt_in_place(v, obj_num, gen, handler) }
        when Objects::Array
          obj.each { |v| encrypt_in_place(v, obj_num, gen, handler) }
        end
      end

      private def encrypt_stream(
        stream : Objects::Stream,
        obj_num : Int32,
        gen : Int32,
        handler : Encryption::StandardSecurity,
      ) : Nil
        # Récupérer les octets encodés (Flate appliqué) AVANT chiffrement.
        encoded = stream.encoded_data
        encrypted = handler.encrypt_object(encoded, obj_num, gen)
        # Remplacer les octets et neutraliser les filtres : `to_pdf`
        # ne les ré-encodera pas. Le Filter du dict reste tel quel —
        # c'est ce que le LECTEUR appliquera APRÈS déchiffrement.
        stream.replace_encoded!(encrypted)
        stream.dictionary[Objects::Name::LENGTH] = Objects::Number.new(encrypted.size)
      end

      private def encrypt_string(
        str : Objects::Str,
        obj_num : Int32,
        gen : Int32,
        handler : Encryption::StandardSecurity,
      ) : Nil
        encrypted = handler.encrypt_object(str.value.to_slice, obj_num, gen)
        str.value = String.new(encrypted)
        # Forcer la sérialisation hex pour la sûreté binaire
        # (les bytes chiffrés peuvent contenir des octets non-printable
        # ou des `(` `)` qui casseraient une string littérale).
        str.hex = true
      end

      private def write_header : String
        # PDF header with version
        # Second line contains high-bit bytes to mark as binary
        "%PDF-#{PDF::PDF_VERSION}\n%\xE2\xE3\xCF\xD3\n"
      end

      private def write_xref : String
        String.build do |io|
          io << "xref\n"

          # We include object 0 (free entry) plus all our objects
          total_objects = @document.objects.size + 1
          io << "0 #{total_objects}\n"

          # Object 0 is always free with generation 65535
          io << "0000000000 65535 f \n"

          # Write entry for each object in order
          (1...total_objects).each do |obj_num|
            offset = @offsets[obj_num]? || 0_i64
            io << offset.to_s.rjust(10, '0')
            io << " 00000 n \n"
          end
        end
      end

      private def write_trailer(
        xref_start : Int64,
        info_ref : Objects::Reference?,
        encrypt_obj_num : Int32?,
      ) : String
        String.build do |io|
          io << "trailer\n"
          io << "<<"
          io << "/Size #{@document.objects.size + 1}"
          io << "/Root #{@document.catalog.reference.to_pdf}"

          if ref = info_ref
            io << "/Info #{ref.to_pdf}"
          end

          if num = encrypt_obj_num
            io << "/Encrypt #{num} 0 R"
          end

          # /ID est obligatoire si /Encrypt est présent (PDF 1.4+) et
          # recommandé sinon. Deux éléments identiques (création +
          # dernière modif) suffisent pour un nouveau document.
          if @document.security_handler || @document.has_file_id?
            id_hex = bytes_to_hex(@document.file_id)
            io << "/ID [<" << id_hex << "><" << id_hex << ">]"
          end

          io << ">>\n"
          io << "startxref\n"
          io << xref_start
          io << "\n%%EOF\n"
        end
      end

      # Builds an object stream (PDF spec § 7.5.7) containing every
      # compressible indirect object of the document, and registers
      # each compressed object's `(container, index)` in `@compressed`
      # so the xref stream can emit type-2 entries.
      #
      # Returns the `Indirect` wrapping the new ObjStm, or nil if
      # nothing was compressible.
      private def build_object_stream : Objects::Indirect?
        # Encryption forbids putting the /Encrypt dict (and a few
        # other special objects) in an ObjStm. We skip any object
        # whose number equals the encrypt slot.
        encrypt_num = @document.security_handler.try do |h|
          # Try to locate the registered /Encrypt indirect by looking
          # for the dict that contains /Filter /Standard.
          @document.objects.find do |ind|
            d = ind.value
            d.is_a?(Objects::Dictionary) && d["Filter"]?.try(&.to_pdf) == "/Standard"
          end.try(&.object_number)
        end

        candidates = @document.objects.select do |ind|
          case ind.value
          when Objects::Stream then false # streams stay standalone
          when Objects::Dictionary        # most dicts can be compressed
            ind.object_number != encrypt_num
          else
            true # arrays, numbers, names, strings, bools, nulls
          end
        end
        return if candidates.empty?

        # Reserve the object number for the ObjStm itself.
        objstm_num = @document.allocate_object_id

        # Serialize each compressed object's body (no `obj`/`endobj`
        # markers — just its value's PDF representation). Track the
        # offsets inside the decoded payload.
        bodies = String.build do |sb|
          candidates.each_with_index do |ind, idx|
            @compressed[ind.object_number] = {objstm_num, idx}
            sb << ind.value.to_pdf
            sb << "\n"
          end
        end

        # Build the leading index (objNum offsetInPayload pairs).
        offset = 0
        index = String.build do |sb|
          candidates.each do |ind|
            sb << ind.object_number << " " << offset << " "
            offset += ind.value.to_pdf.bytesize + 1 # +1 for "\n"
          end
        end.rstrip(' ')

        payload = "#{index}\n#{bodies}"
        first_byte = index.bytesize + 1 # past the "\n"

        stream = Objects::Stream.new
        stream["Type"] = Objects::Name.new("ObjStm")
        stream["N"] = Objects::Number.new(candidates.size)
        stream["First"] = Objects::Number.new(first_byte)
        stream.data = payload
        stream.add_filter(Filters::Flate.new)

        Objects::Indirect.new(objstm_num, stream)
      end

      # Builds the cross-reference stream as an Indirect object.
      # The stream contains binary entries `[type, offset, gen]`, one
      # per object slot. Widths are chosen to fit the largest offset.
      private def build_xref_indirect(
        xref_num : Int32,
        info_ref : Objects::Reference?,
        encrypt_obj_num : Int32?,
      ) : Objects::Indirect
        # The xref entry table covers object 0..xref_num inclusive.
        total = xref_num + 1

        max_offset = @offsets.values.max
        w_offset = bytes_needed(max_offset)
        w_gen = 2 # 2 bytes always suffice (max 65535)

        payload = IO::Memory.new
        # Object 0 : free, offset 0, generation 65535.
        write_xref_entry(payload, 0, 0_i64, 65535, w_offset, w_gen)
        (1..xref_num).each do |n|
          if entry = @compressed[n]?
            # Type 2 : object n lives inside ObjStm entry[0] at
            # index entry[1]. Generation is always 0 for compressed.
            write_xref_entry(payload, 2, entry[0].to_i64, entry[1], w_offset, w_gen)
          else
            offset = @offsets[n]? || 0_i64
            # Type 1 : regular in-use indirect at byte offset.
            write_xref_entry(payload, 1, offset, 0, w_offset, w_gen)
          end
        end

        stream = Objects::Stream.new
        stream["Type"] = Objects::Name.new("XRef")
        stream["Size"] = Objects::Number.new(total)
        stream["Root"] = @document.catalog.reference
        if ref = info_ref
          stream["Info"] = ref
        end
        if num = encrypt_obj_num
          stream["Encrypt"] = Objects::Reference.new(num)
        end
        if @document.security_handler || @document.has_file_id?
          id_str = Objects::Str.new(String.new(@document.file_id), hex: true)
          id_arr = Objects::Array.new
          id_arr << id_str
          id_arr << id_str
          stream["ID"] = id_arr
        end
        w = Objects::Array.new
        w << Objects::Number.new(1)
        w << Objects::Number.new(w_offset)
        w << Objects::Number.new(w_gen)
        stream["W"] = w
        stream.data = payload.to_slice
        stream.add_filter(Filters::Flate.new)

        Objects::Indirect.new(xref_num, stream)
      end

      # Writes a single xref entry as `1 + w_offset + w_gen` bytes
      # (big-endian).
      private def write_xref_entry(
        io : IO,
        type : Int32,
        offset : Int64,
        gen : Int32,
        w_offset : Int32,
        w_gen : Int32,
      ) : Nil
        io.write_byte(type.to_u8)
        write_big_endian(io, offset, w_offset)
        write_big_endian(io, gen.to_i64, w_gen)
      end

      private def write_big_endian(io : IO, value : Int64, width : Int32) : Nil
        (width - 1).downto(0) do |i|
          io.write_byte(((value >> (i * 8)) & 0xff).to_u8)
        end
      end

      # Smallest number of bytes needed to encode `n` as unsigned.
      private def bytes_needed(n : Int) : Int32
        return 1 if n < 0x100
        return 2 if n < 0x10000
        return 3 if n < 0x1000000
        return 4 if n < 0x100000000
        8
      end

      private def bytes_to_hex(bytes : Bytes) : String
        String.build do |sb|
          bytes.each { |b| sb << b.to_s(16, upcase: true).rjust(2, '0') }
        end
      end
    end
  end
end
