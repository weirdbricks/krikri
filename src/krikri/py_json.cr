require "json"

module Krikri
  # The failure text of Python's json.loads, for callers whose own JSON
  # parse just failed. ansible's from_json filter surfaces that
  # exception's message verbatim, so a role that pipes an empty stdout
  # into `| from_json` really fails with "Expecting value: line 1
  # column 1 (char 0)" - not with a generic invalid-JSON wording.
  #
  # Positions and wordings are a port of CPython's C scanner
  # (Modules/_json.c, the implementation json.loads actually runs). The
  # pure-Python decoder reports several positions differently (it points
  # at the escaped character where the C scanner points at the
  # backslash), so the C one is the reference.
  module PyJson
    class ScanError < Exception
      getter reason : String
      getter position : Int32

      def initialize(@reason : String, @position : Int32)
        super(@reason)
      end
    end

    # The short escapes CPython's scanner accepts after a backslash.
    private ESCAPE_CHARS = "\"\\/bfnrt"

    # Python's JSONDecodeError message for the first syntax error in
    # *text*. Callers only reach this after their own parse failed.
    def self.error_message(text : String) : String
      # json.loads rejects a leading BOM before scanning at all (the str
      # branch of its decode), so that text never reaches the parser.
      if text.starts_with?('\ufeff')
        return "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"
      end
      chars = text.chars
      begin
        idx = skip_whitespace(chars, 0)
        idx = scan_once(chars, idx)
        idx = skip_whitespace(chars, idx)
        raise ScanError.new("Extra data", idx) if idx != chars.size
      rescue ex : ScanError
        return format_message(chars, ex.reason, ex.position)
      end
      # Unreachable for callers (they parse first); an error-message
      # helper must still never raise.
      format_message(chars, "Expecting value", 0)
    end

    private def self.format_message(chars : Array(Char), reason : String, position : Int32) : String
      lineno = 1
      last_newline = -1
      i = 0
      while i < position && i < chars.size
        if chars[i] == '\n'
          lineno += 1
          last_newline = i
        end
        i += 1
      end
      colno = position - last_newline
      "#{reason}: line #{lineno} column #{colno} (char #{position})"
    end

    private def self.whitespace?(char : Char) : Bool
      char == ' ' || char == '\t' || char == '\n' || char == '\r'
    end

    private def self.skip_whitespace(chars : Array(Char), idx : Int32) : Int32
      while idx < chars.size && whitespace?(chars[idx])
        idx += 1
      end
      idx
    end

    private def self.digit?(char : Char) : Bool
      char >= '0' && char <= '9'
    end

    private def self.at_char?(chars : Array(Char), idx : Int32, last : Int32, char : Char) : Bool
      idx <= last && chars[idx] == char
    end

    # Returns the index just past the value starting at *idx*.
    private def self.scan_once(chars : Array(Char), idx : Int32) : Int32
      raise ScanError.new("Expecting value", idx) if idx >= chars.size

      case chars[idx]
      when '"'
        return scan_string(chars, idx + 1)
      when '{'
        return scan_object(chars, idx + 1)
      when '['
        return scan_array(chars, idx + 1)
      end

      constant_end(chars, idx) || scan_number(chars, idx)
    end

    # null / true / false / NaN / Infinity / -Infinity: the index just
    # past the literal, or nil when this is not one of them (CPython then
    # tries to read a number instead).
    private def self.constant_end(chars : Array(Char), idx : Int32) : Int32?
      case chars[idx]
      when 'n'
        idx + 4 if literal_at?(chars, idx + 1, "ull")
      when 't'
        idx + 4 if literal_at?(chars, idx + 1, "rue")
      when 'f'
        idx + 5 if literal_at?(chars, idx + 1, "alse")
      when 'N'
        idx + 3 if literal_at?(chars, idx + 1, "aN")
      when 'I', '-'
        infinity_end(chars, idx)
      end
    end

    private def self.infinity_end(chars : Array(Char), idx : Int32) : Int32?
      if chars[idx] == '-'
        idx + 9 if literal_at?(chars, idx + 1, "Infinity")
      else
        idx + 8 if literal_at?(chars, idx + 1, "nfinity")
      end
    end

    # Whether *literal* sits at *start*, fully inside the document - the
    # same bounds the C scanner's lookahead uses.
    private def self.literal_at?(chars : Array(Char), start : Int32, literal : String) : Bool
      return false if start + literal.size > chars.size
      literal.each_char_with_index do |char, offset|
        return false unless chars[start + offset] == char
      end
      true
    end

    # *idx* is the index just past the opening quote.
    private def self.scan_string(chars : Array(Char), idx : Int32) : Int32
      length = chars.size
      begin_idx = idx - 1
      while true
        idx = next_string_terminator(chars, idx, begin_idx)
        char = chars[idx]
        idx += 1
        return idx if char == '"'
        raise ScanError.new("Unterminated string starting at", begin_idx) if idx >= length
        idx = skip_escape(chars, idx)
      end
    end

    # Index of the next quote or backslash. A literal control character
    # and a run to the end of the document are errors here, as in
    # CPython's scanstring.
    private def self.next_string_terminator(chars : Array(Char), idx : Int32, begin_idx : Int32) : Int32
      while idx < chars.size
        char = chars[idx]
        return idx if char == '"' || char == '\\'
        raise ScanError.new("Invalid control character at", idx) if char.ord <= 0x1f
        idx += 1
      end
      raise ScanError.new("Unterminated string starting at", begin_idx)
    end

    # *idx* is the index just past a backslash; returns the index just
    # past that escape sequence. A high surrogate followed by a real \u
    # escape reads as one code point; otherwise CPython rewinds to the
    # backslash, so it starts the next escape sequence instead.
    private def self.skip_escape(chars : Array(Char), idx : Int32) : Int32
      escape = chars[idx]
      if escape != 'u'
        raise ScanError.new("Invalid \\escape", idx - 1) unless ESCAPE_CHARS.includes?(escape)
        return idx + 1
      end

      uni = decode_hex_escape(chars, idx)
      idx += 5
      unless high_surrogate?(uni) && idx + 6 < chars.size && chars[idx] == '\\' && chars[idx + 1] == 'u'
        return idx
      end
      second = decode_hex_escape(chars, idx + 1)
      low_surrogate?(second) ? idx + 6 : idx
    end

    private def self.high_surrogate?(value : Int32) : Bool
      0xd800 <= value <= 0xdbff
    end

    private def self.low_surrogate?(value : Int32) : Bool
      0xdc00 <= value <= 0xdfff
    end

    # Decodes the four hex digits after the 'u' at *u_idx*; CPython
    # reports a bad or truncated sequence at the 'u' itself. Its bound
    # is `>= len' (Modules/_json.c), so an escape whose last hex digit
    # ends the document is "truncated" too.
    private def self.decode_hex_escape(chars : Array(Char), u_idx : Int32) : Int32
      if u_idx + 5 >= chars.size
        raise ScanError.new("Invalid \\uXXXX escape", u_idx)
      end
      value = 0
      (1..4).each do |offset|
        digit = hex_value(chars[u_idx + offset])
        raise ScanError.new("Invalid \\uXXXX escape", u_idx) unless digit
        value = (value << 4) | digit
      end
      value
    end

    private def self.hex_value(char : Char) : Int32?
      case char
      when '0'..'9' then char.ord - '0'.ord
      when 'a'..'f' then char.ord - 'a'.ord + 10
      when 'A'..'F' then char.ord - 'A'.ord + 10
      end
    end

    private def self.scan_number(chars : Array(Char), start : Int32) : Int32
      last = chars.size - 1
      idx = start
      if chars[idx] == '-'
        idx += 1
        raise ScanError.new("Expecting value", start) if idx > last
      end
      idx = scan_integer_part(chars, idx, start, last)
      idx = scan_fraction(chars, idx, last)
      scan_exponent(chars, idx, last)
    end

    private def self.scan_integer_part(chars : Array(Char), idx : Int32, start : Int32, last : Int32) : Int32
      char = chars[idx]
      if char >= '1' && char <= '9'
        idx += 1
        while idx <= last && digit?(chars[idx])
          idx += 1
        end
      elsif char == '0'
        idx += 1
      else
        raise ScanError.new("Expecting value", start)
      end
      idx
    end

    private def self.scan_fraction(chars : Array(Char), idx : Int32, last : Int32) : Int32
      return idx unless idx < last && chars[idx] == '.' && digit?(chars[idx + 1])

      idx += 2
      while idx <= last && digit?(chars[idx])
        idx += 1
      end
      idx
    end

    # An exponent only counts when it has at least one digit; otherwise
    # CPython leaves the 'e' to be reported as trailing data.
    private def self.scan_exponent(chars : Array(Char), idx : Int32, last : Int32) : Int32
      return idx unless idx < last && (chars[idx] == 'e' || chars[idx] == 'E')

      exponent_start = idx
      idx += 1
      idx += 1 if idx < last && (chars[idx] == '-' || chars[idx] == '+')
      while idx <= last && digit?(chars[idx])
        idx += 1
      end
      digit?(chars[idx - 1]) ? idx : exponent_start
    end

    private def self.scan_object(chars : Array(Char), idx : Int32) : Int32
      last = chars.size - 1
      idx = skip_whitespace(chars, idx)
      return idx + 1 if at_char?(chars, idx, last, '}')

      while true
        idx = scan_object_pair(chars, idx, last)
        break if at_char?(chars, idx, last, '}')
        raise ScanError.new("Expecting ',' delimiter", idx) unless at_char?(chars, idx, last, ',')
        idx = skip_comma(chars, idx, last, '}', "Illegal trailing comma before end of object")
      end

      idx + 1
    end

    # One key/value pair, returning the index just past the value's
    # trailing whitespace.
    private def self.scan_object_pair(chars : Array(Char), idx : Int32, last : Int32) : Int32
      unless at_char?(chars, idx, last, '"')
        raise ScanError.new("Expecting property name enclosed in double quotes", idx)
      end
      idx = skip_whitespace(chars, scan_string(chars, idx + 1))
      unless at_char?(chars, idx, last, ':')
        raise ScanError.new("Expecting ':' delimiter", idx)
      end
      skip_whitespace(chars, scan_once(chars, skip_whitespace(chars, idx + 1)))
    end

    private def self.scan_array(chars : Array(Char), idx : Int32) : Int32
      last = chars.size - 1
      idx = skip_whitespace(chars, idx)
      return idx + 1 if at_char?(chars, idx, last, ']')

      while true
        idx = skip_whitespace(chars, scan_once(chars, idx))
        break if at_char?(chars, idx, last, ']')
        raise ScanError.new("Expecting ',' delimiter", idx) unless at_char?(chars, idx, last, ',')
        idx = skip_comma(chars, idx, last, ']', "Illegal trailing comma before end of array")
      end

      # CPython's own sanity check after the loop.
      raise ScanError.new("Expecting value", last) unless at_char?(chars, idx, last, ']')
      idx + 1
    end

    # Consumes the comma at *idx* and the whitespace after it; a closing
    # bracket right behind a comma is an error reported at the comma.
    private def self.skip_comma(chars : Array(Char), idx : Int32, last : Int32, closing : Char, message : String) : Int32
      comma_idx = idx
      idx = skip_whitespace(chars, idx + 1)
      raise ScanError.new(message, comma_idx) if at_char?(chars, idx, last, closing)
      idx
    end
  end
end
