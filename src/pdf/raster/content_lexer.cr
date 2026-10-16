module PDF
  module Raster
    # Tokeniseur de flux de contenu PDF (ISO 32000-1 § 7.8.2) pour le
    # rasterizer. Produit une suite de jetons : nombres, noms,
    # chaînes, délimiteurs de tableau / dictionnaire, et opérateurs.
    #
    # Les images en ligne (`BI … ID … EI`) sont sautées en bloc — leurs
    # données binaires ne doivent pas être interprétées comme des
    # jetons. Le rendu des images en ligne est hors périmètre du MVP.
    module ContentLexer
      # Un jeton du flux de contenu. `kind` ∈ {:num, :name, :str, :op,
      # :array_start, :array_end, :dict_start, :dict_end}. Pour `:str`,
      # `bytes` porte le contenu décodé (utile au rendu de texte).
      record Token,
        kind : Symbol,
        num : Float64 = 0.0,
        text : String = "",
        bytes : Bytes = Bytes.empty

      WHITESPACE = {' ', '\t', '\r', '\n', '\f', '\0'}
      DELIMITERS = {'(', ')', '<', '>', '[', ']', '{', '}', '/', '%'}

      # Découpe les octets d'un flux de contenu en jetons.
      def self.tokenize(data : Bytes) : Array(Token)
        tokens = [] of Token
        i = 0
        n = data.size
        while i < n
          c = data[i].unsafe_chr
          if WHITESPACE.includes?(c)
            i += 1
          elsif c == '%'
            i += 1
            while i < n && data[i] != 0x0A_u8 && data[i] != 0x0D_u8
              i += 1
            end
          elsif c == '['
            tokens << Token.new(:array_start)
            i += 1
          elsif c == ']'
            tokens << Token.new(:array_end)
            i += 1
          elsif c == '<' && i + 1 < n && data[i + 1].unsafe_chr == '<'
            tokens << Token.new(:dict_start)
            i += 2
          elsif c == '>' && i + 1 < n && data[i + 1].unsafe_chr == '>'
            tokens << Token.new(:dict_end)
            i += 2
          elsif c == '('
            i = lex_literal_string(data, i, tokens)
          elsif c == '<'
            i = lex_hex_string(data, i, tokens)
          elsif c == '/'
            i = lex_name(data, i, tokens)
          elsif c == '+' || c == '-' || c == '.' || ('0' <= c <= '9')
            i = lex_number(data, i, tokens)
          else
            i = lex_operator(data, i, tokens)
          end
        end
        tokens
      end

      private def self.lex_number(data : Bytes, start : Int32, tokens : Array(Token)) : Int32
        i = start
        n = data.size
        while i < n
          c = data[i].unsafe_chr
          break unless c == '+' || c == '-' || c == '.' || c == 'e' || c == 'E' || ('0' <= c <= '9')
          i += 1
        end
        slice = String.new(data[start, i - start])
        tokens << Token.new(:num, num: slice.to_f64? || 0.0)
        i
      end

      private def self.lex_name(data : Bytes, start : Int32, tokens : Array(Token)) : Int32
        i = start + 1 # saute '/'
        n = data.size
        while i < n
          c = data[i].unsafe_chr
          break if WHITESPACE.includes?(c) || DELIMITERS.includes?(c)
          i += 1
        end
        tokens << Token.new(:name, text: String.new(data[start + 1, i - start - 1]))
        i
      end

      private def self.lex_operator(data : Bytes, start : Int32, tokens : Array(Token)) : Int32
        i = start
        n = data.size
        while i < n
          c = data[i].unsafe_chr
          break if WHITESPACE.includes?(c) || DELIMITERS.includes?(c)
          i += 1
        end
        op = String.new(data[start, i - start])
        # Image en ligne : sauter jusqu'à `EI`.
        if op == "BI"
          return skip_inline_image(data, i)
        end
        tokens << Token.new(:op, text: op) unless op.empty?
        i
      end

      private def self.lex_literal_string(data : Bytes, start : Int32, tokens : Array(Token)) : Int32
        i = start + 1
        n = data.size
        depth = 1
        buf = IO::Memory.new
        while i < n && depth > 0
          c = data[i]
          if c == '\\'.ord
            i += 1
            break if i >= n
            e = data[i].unsafe_chr
            case e
            when 'n'  then buf.write_byte(0x0A_u8); i += 1
            when 'r'  then buf.write_byte(0x0D_u8); i += 1
            when 't'  then buf.write_byte(0x09_u8); i += 1
            when 'b'  then buf.write_byte(0x08_u8); i += 1
            when 'f'  then buf.write_byte(0x0C_u8); i += 1
            when '('  then buf.write_byte('('.ord.to_u8); i += 1
            when ')'  then buf.write_byte(')'.ord.to_u8); i += 1
            when '\\' then buf.write_byte('\\'.ord.to_u8); i += 1
            when '\n' then i += 1 # continuation de ligne
            when '\r' then i += 1; i += 1 if i < n && data[i].unsafe_chr == '\n'
            else
              if '0' <= e <= '7'
                val = 0
                k = 0
                while k < 3 && i < n && '0' <= data[i].unsafe_chr <= '7'
                  val = val * 8 + (data[i] - '0'.ord)
                  i += 1
                  k += 1
                end
                buf.write_byte((val & 0xFF).to_u8)
              else
                buf.write_byte(data[i]); i += 1
              end
            end
          elsif c == '('.ord
            depth += 1
            buf.write_byte(c)
            i += 1
          elsif c == ')'.ord
            depth -= 1
            buf.write_byte(c) if depth > 0
            i += 1
          else
            buf.write_byte(c)
            i += 1
          end
        end
        tokens << Token.new(:str, bytes: buf.to_slice)
        i
      end

      private def self.lex_hex_string(data : Bytes, start : Int32, tokens : Array(Token)) : Int32
        i = start + 1
        n = data.size
        nibbles = [] of UInt8
        while i < n && data[i].unsafe_chr != '>'
          c = data[i].unsafe_chr
          if v = hex_value(c)
            nibbles << v
          end
          i += 1
        end
        i += 1 if i < n
        nibbles << 0_u8 if nibbles.size.odd?
        bytes = Bytes.new(nibbles.size // 2)
        (0...bytes.size).each { |j| bytes[j] = (nibbles[j * 2] << 4 | nibbles[j * 2 + 1]) }
        tokens << Token.new(:str, bytes: bytes)
        i
      end

      private def self.hex_value(c : Char) : UInt8?
        case c
        when '0'..'9' then (c.ord - '0'.ord).to_u8
        when 'a'..'f' then (c.ord - 'a'.ord + 10).to_u8
        when 'A'..'F' then (c.ord - 'A'.ord + 10).to_u8
        end
      end

      private def self.skip_inline_image(data : Bytes, start : Int32) : Int32
        i = start
        n = data.size
        # Cherche la séquence `EI` délimitée par des espaces.
        while i < n - 1
          if data[i].unsafe_chr == 'E' && data[i + 1].unsafe_chr == 'I' &&
             (i + 2 >= n || WHITESPACE.includes?(data[i + 2].unsafe_chr))
            return i + 2
          end
          i += 1
        end
        n
      end
    end
  end
end
