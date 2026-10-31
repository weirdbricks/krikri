require "big"
require "json"
require "./param_sentinels"

module Krikri
  # The bigint-aware JSON parse for module (plugin) wire results.
  #
  # A plugin's stdout is parsed into the JSON::Any tree everything
  # downstream (registered variables, templating, filters, display)
  # carries - and JSON::Any's raw union tops out at Int64, so plain
  # JSON.parse raises "Invalid Int64" the moment a module returns a
  # wider integer (an RSA modulus, an EC coordinate, a big certificate
  # serial number - the exact bytes the real modules print). This parser
  # first rewrites every integer literal that does not fit Int64 into
  # the BIGINT_SENTINEL_PREFIX-marked decimal string (quoted, with the
  # marker escaped) and then lets plain JSON.parse build the tree, so
  # the wide value arrives as a marked string that every renderer taught
  # about the sentinel prints back as bare unquoted digits - the text
  # Ansible's Python ints produce.
  #
  # The rewrite is a small scanner rather than a pull-parser walk:
  # JSON::PullParser lexes wide integers fine, but its `skip` desyncs the
  # token buffer inside nested containers (the next object key comes
  # back stale), so a manual tree build over it is not trustworthy. The
  # scanner walks the text once, tracks JSON string literals (with
  # escapes) so a number inside a string is never touched, and rewrites
  # only bare `-digits` tokens; anything with a fraction or exponent is
  # a float and goes through verbatim. Behavior otherwise mirrors
  # JSON.parse exactly - same tree shapes, last-wins duplicate keys, and
  # identical errors (the rewrite only ever ADDS quoting around digits),
  # so the callers' rescue paths keep working unchanged.
  module BigJson
    def self.parse(text : String) : JSON::Any
      JSON.parse(quote_wide_ints(text))
    end

    # An integer literal wider than 18 digits MIGHT exceed Int64
    # (Int64::MAX is 19 digits); anything shorter never does, so
    # documents without such a run skip the scan entirely.
    private WIDE_INT_HINT = /\d{19,}/

    private def self.quote_wide_ints(text : String) : String
      return text unless text.size > 18 && text.matches?(WIDE_INT_HINT)

      String.build(text.size) do |out_io|
        in_string = false
        escaped = false
        i = 0
        size = text.size
        while i < size
          char = text[i]
          if in_string
            out_io << char
            if escaped
              escaped = false
            elsif char == '\\'
              escaped = true
            elsif char == '"'
              in_string = false
            end
            i += 1
            next
          end
          if char == '"'
            in_string = true
            out_io << char
            i += 1
            next
          end
          if char == '-' || char.ascii_number?
            i = rewrite_number(text, i, out_io)
            next
          end
          out_io << char
          i += 1
        end
      end
    end

    # Copies the number token starting at *start* to *out_io*, wrapping it
    # in a sentinel-marked JSON string when it is a bare integer that does
    # not fit Int64. Returns the index just past the token.
    private def self.rewrite_number(text : String, start : Int32, out_io : IO) : Int32
      i = start
      negative = text[i] == '-'
      i += 1 if negative
      digit_start = i
      i = scan_digits(text, i)
      digits = negative ? "-#{text[digit_start...i]}" : text[digit_start...i]
      i, float = skip_float_tail(text, i)

      if float || digits.to_i64?
        out_io << text[start...i]
      else
        # \uE000 escaped: JSON.parse decodes it back to the marker char,
        # and the escape keeps the rewrite's own output independent of
        # how a transport handles raw non-ASCII bytes.
        out_io << '"' << "\\uE000bigint:" << digits << '"'
      end
      i
    end

    private def self.scan_digits(text : String, i : Int32) : Int32
      size = text.size
      while i < size && text[i].ascii_number?
        i += 1
      end
      i
    end

    # Skips the fraction and/or exponent tail of a number token starting
    # at *i*, returning the index past it and whether either was present
    # (either makes the literal a float, never a sentinel candidate). The
    # fraction and a following exponent are consumed TOGETHER: stopping
    # after the fraction re-presented the exponent digits to the main
    # loop as a fresh number token, so a long-exponent float
    # (`1.5e12345678901234567890`) had its exponent wrapped into a
    # sentinel-quoted string and the document stopped being valid JSON.
    private def self.skip_float_tail(text : String, i : Int32) : {Int32, Bool}
      size = text.size
      float = false
      j = i
      if j < size && text[j] == '.'
        float = true
        j = scan_digits(text, j + 1)
      end
      if j < size && (text[j] == 'e' || text[j] == 'E')
        float = true
        j += 1
        j += 1 if j < size && (text[j] == '+' || text[j] == '-')
        j = scan_digits(text, j)
      end
      {j, float}
    end

    # Exact ordering of a wide integer (the decimal digits of a
    # BIGINT_SENTINEL_PREFIX-marked value, sign included) against a
    # Float64. The naive route - converting the digits to Float64 and
    # using `<=>` - raises "Invalid Float64" the moment the integer
    # overflows Float64's range (a 617-digit RSA modulus), and even in
    # range it would round. Python's int/float comparison is exact
    # arithmetic, so this is too: the float decomposes exactly as
    # mantissa * 2^exponent (Math.frexp is exact for IEEE doubles), both
    # sides are scaled to integers with a BigInt shift, and the compare
    # is a plain digit compare. A magnitude pre-gate on digit count
    # (|big| lies in [10^(d-1), 10^d)) settles everything outside the
    # one-decade band around the float without building a BigInt at all.
    def self.bigint_cmp_float(digits : String, f : Float64) : Int32
      return 0 if f.nan?
      neg = digits.starts_with?('-')
      magnitude_sign_case(neg ? digits[1..] : digits, f, neg)
    end

    # The sign-combining wrapper: compares |big| against |f|, then applies
    # the two operands' signs (like Krikri.bigint_cmp's own sign rule).
    private def self.magnitude_sign_case(mag : String, f : Float64, neg : Bool) : Int32
      return f > 0 ? -1 : 1 if f.infinite?
      return f > 0 ? -1 : (f < 0 ? 1 : 0) if mag == "0"
      return neg ? -1 : 1 if f == 0.0

      mag_cmp = magnitude_cmp_float(mag, f.abs)
      if neg && f < 0
        -mag_cmp
      elsif neg
        -1
      elsif f < 0
        1
      else
        mag_cmp
      end
    end

    # |big| <=> |f| for a nonzero unsigned digit string and a finite
    # positive float.
    private def self.magnitude_cmp_float(mag : String, af : Float64) : Int32
      logf = Math.log10(af)
      return 1 if mag.size - 1 > logf
      return -1 if mag.size < logf

      # Exact band: af = m53 * 2^e with m53 an integer of at most 53 bits
      # (frac * 2^53 is exactly representable, so the to_i64 is lossless).
      bi = BigInt.new(mag)
      frac, exp = Math.frexp(af)
      m53 = (frac * 9007199254740992.0).round.to_i64
      e = exp - 53
      if e >= 0
        bi <=> (BigInt.new(m53) << e)
      else
        (bi << -e) <=> BigInt.new(m53)
      end
    end
  end
end
