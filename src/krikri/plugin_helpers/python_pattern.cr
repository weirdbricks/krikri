# PythonPattern - a scan of a user-supplied pattern through Python's own
# re._parser tokenizer semantics, shared by the file-editing plugins
# (replace, lineinfile). It rejects first what PCRE2 would happily
# compile but Ansible's Python rejects, rewrites the two escape forms
# Python accepts and PCRE2 does not (\uXXXX, \Uhhhhhhhh), and carries
# the positions python_pcre_error needs to translate a PCRE2 compile
# error into the re.error wording Ansible's user actually sees. Lived
# in the replace plugin until lineinfile needed the same machinery:
# real lineinfile.py compiles regexp: (and a non-literal
# insertafter:/insertbefore: anchor) with a bare re.compile no except
# clause catches, so a bad pattern crashes the module instead of
# silently matching nothing.
module Krikri
  module PythonPattern
    # The scan result: the PCRE2-ready pattern, the first Python-re
    # error the scan can state exactly (nil when none), and the two
    # positions python_pcre_error needs when PCRE2 itself rejects the
    # pattern: the innermost unterminated '(' and the '[' of an
    # unterminated character class, both in ORIGINAL pattern
    # coordinates. Each \u/\U rewrite is remembered as {output char
    # index, output length, source char index} so PCRE2 error
    # positions can be mapped back through it.
    record Scan, translated : String, error : String?,
      unclosed_paren : Int32?, open_class_start : Int32?,
      rewrites : Array({Int32, Int32, Int32})?

    # Mutable scan cursor: the tokenizer is a single left-to-right pass
    # whose branches all advance the same cursor and append to the same
    # builder, so the per-character handlers share one context object
    # instead of threading six values through every call.
    private class Context
      getter chars : Array(Char)
      getter size : Int32
      getter builder : String::Builder
      getter rewrites : Array({Int32, Int32, Int32})
      getter paren_stack : Array(Int32)
      property builder_chars : Int32
      property class_start : Int32
      property? in_class : Bool
      property error : String?
      property index : Int32

      def initialize(pattern : String)
        @chars = pattern.chars
        @size = @chars.size
        @builder = String::Builder.new
        @builder_chars = 0
        @rewrites = [] of {Int32, Int32, Int32}
        @paren_stack = [] of Int32
        @class_start = 0
        @in_class = false
        @error = nil
        @index = 0
      end

      def append(char : Char)
        builder << char
        self.builder_chars += 1
      end
    end

    def self.scan(pattern : String) : Scan
      ctx = Context.new(pattern)
      while ctx.index < ctx.size && ctx.error.nil?
        if ctx.in_class?
          scan_class_char(ctx)
        else
          scan_code_char(ctx)
        end
      end
      if error = ctx.error
        return Scan.new(pattern, error, nil, nil, nil)
      end
      rewrites = ctx.rewrites
      Scan.new(ctx.builder.to_s, nil, ctx.paren_stack.last?,
        ctx.in_class? ? ctx.class_start : nil, rewrites.empty? ? nil : rewrites)
    end

    # One character inside an unterminated-so-far character class:
    # escapes check (and may rewrite) exactly as outside, ']' closes
    # the class, anything else copies raw.
    private def self.scan_class_char(ctx : Context)
      chars = ctx.chars
      i = ctx.index
      case chars[i]
      when '\\'
        consumed, err, replacement = check_escape(chars, i, true)
        if err
          ctx.error = err
          return
        end
        emit_escape(ctx, consumed, replacement, i)
      when ']'
        ctx.in_class = false
        ctx.append(']')
        ctx.index += 1
      else
        ctx.append(chars[i])
        ctx.index += 1
      end
    end

    # One character outside any character class: escapes, class open,
    # group open/close, plain copy.
    private def self.scan_code_char(ctx : Context)
      chars = ctx.chars
      i = ctx.index
      case chars[i]
      when '\\'
        consumed, err, replacement = check_escape(chars, i, false)
        if err
          ctx.error = err
          return
        end
        emit_escape(ctx, consumed, replacement, i)
      when '['
        open_class(ctx)
      when '('
        scan_group(ctx)
      when ')'
        ctx.paren_stack.pop?
        ctx.append(')')
        ctx.index += 1
      else
        ctx.append(chars[i])
        ctx.index += 1
      end
    end

    # Emits one escape (or its \u/\U replacement, remembered for the
    # position mapping) into the builder and advances the cursor - the
    # shared tail of the in-class and outside-class escape branches.
    private def self.emit_escape(ctx : Context, consumed : Int32, replacement : String?, source : Int32)
      if rep = replacement
        ctx.rewrites << {ctx.builder_chars, rep.size, source}
        ctx.builder << rep
        ctx.builder_chars += rep.size
      else
        ctx.chars[source, consumed].each do |source_char|
          ctx.append(source_char)
        end
      end
      ctx.index += consumed
    end

    private def self.open_class(ctx : Context)
      chars = ctx.chars
      i = ctx.index
      # PCRE2 probes '[' + ':'/'.'/'=' + ... + 'terminator]' at the TOP
      # level and refuses the whole pattern as a POSIX class/collating/
      # equivalence reference ("POSIX named classes are supported only
      # within a class", zhan9san.jenkins's `regexp: '^\s*listen
      # [::]:80;'`), where Python just opens a literal class - Python's
      # tokenizer never looks for POSIX syntax outside a class. Escaping
      # the member char defuses the PCRE2 misread without changing the
      # Python membership; the rewrite is recorded so a later PCRE2
      # compile error still maps back to source offsets.
      if lead = posix_misread_lead?(chars, i, ctx.size)
        ctx.in_class = true
        ctx.class_start = i
        ctx.rewrites << {ctx.builder_chars, 3, i}
        ctx.append('[')
        ctx.append('\\')
        ctx.append(lead)
        ctx.index = i + 2
        return
      end
      # ']' as the first class member (after an optional ^) is
      # literal, exactly as Python's tokenizer treats it
      ctx.in_class = true
      ctx.class_start = i
      j = i + 1
      j += 1 if chars[j]? == '^'
      j += 1 if chars[j]? == ']'
      while i < j
        ctx.append(chars[i])
        i += 1
      end
      ctx.index = i
    end

    # The lead char (':', '.' or '=') when PCRE2's top-level
    # POSIX-syntax probe (check_posix_syntax) fires for the class opening
    # at chars[open], nil when the '[' parses as a plain class in both
    # engines. The probe takes the char after '[' as its terminator, then
    # scans forward - honouring backslash escapes, stopping at the first
    # unescaped ']' - for 'terminator]'. Verified against PCRE2 10.x via
    # Crystal Regex: '[:a[b]:]' and '[:a]b:]' compile (the probe aborts at
    # the bare ']'), '[:\]:]' does not (the escape is skipped), '[.:]' and
    # '[=:]' do (the probe needs the terminator+']' pair, not just ']').
    private def self.posix_misread_lead?(chars : Array(Char), open : Int32, size : Int32) : Char?
      lead = chars[open + 1]?
      return nil unless lead == ':' || lead == '.' || lead == '='
      j = open + 2
      while j < size
        case chars[j]
        when '\\'
          j += 2
        when ']'
          return nil
        else
          return lead if chars[j] == lead && chars[j + 1]? == ']'
          j += 1
        end
      end
      nil
    end

    private def self.scan_group(ctx : Context)
      chars = ctx.chars
      i = ctx.index
      size = ctx.size
      ctx.paren_stack << i
      if i + 1 < size && chars[i + 1] == '?'
        if err = check_extension(chars, i, size)
          ctx.error = err
          return
        end
        marker = chars[i + 2]
        if marker == '#'
          scan_comment_group(ctx)
          return
        elsif marker.in?('i', 'L', 'm', 's', 'x', 'a', 'u', '-')
          ctx.error = check_flags(chars, i + 2, size)
          return if ctx.error
        end
      end
      ctx.append('(')
      ctx.index += 1
    end

    # A (?#...) comment: Python skips raw to its own ')' - which also
    # balances the '(' this scanner pushed, without ever opening a
    # group.
    private def self.scan_comment_group(ctx : Context)
      chars = ctx.chars
      i = ctx.index
      j = i + 3
      while j < ctx.size && chars[j] != ')'
        j += 1
      end
      if j >= ctx.size
        ctx.error = "missing ), unterminated comment at position #{ctx.paren_stack.last}"
        return
      end
      ctx.paren_stack.pop
      while i <= j
        ctx.append(chars[i])
        i += 1
      end
      ctx.index = i
    end

    # After '(': Python's extension dispatch, exactly as
    # re._parser._parse orders it. The accepted set is Python 3.13's
    # own: P/:/#/=/!/< (only with =/!)/(/(>/atomic and the inline
    # flags; everything else is an re.error whose position is the
    # index of the '?'.
    private def self.check_extension(chars : Array(Char), i : Int32, size : Int32) : String?
      if i + 2 >= size
        return "unexpected end of pattern at position #{size}"
      end
      case chars[i + 2]
      when 'P'
        if i + 3 >= size
          return "unexpected end of pattern at position #{size}"
        end
        following = chars[i + 3]
        unless following == '<' || following == '='
          return "unknown extension ?P#{following} at position #{i + 1}"
        end
      when '<'
        if i + 3 >= size
          return "unexpected end of pattern at position #{size}"
        end
        following = chars[i + 3]
        unless following == '=' || following == '!'
          return "unknown extension ?<#{following} at position #{i + 1}"
        end
      when ':', '#', '=', '!', '(', '>'
        nil
      when 'i', 'L', 'm', 's', 'x', 'a', 'u', '-'
        check_flags(chars, i + 2, size)
      else
        "unknown extension ?#{chars[i + 2]} at position #{i + 1}"
      end
    end

    # The inline-flag section between "(?" and its ':' or ')'
    # terminator: flag chars i/L/m/s/x/a/u with optional '-' groups -
    # Python's "missing flag" fires when a '-' (or the section) meets
    # a non-flag, and "missing -, : or )" when the section never
    # terminates. (The semantic checks Python then applies - L with a
    # str pattern, a/u negation - stay unchecked.)
    private def self.check_flags(chars : Array(Char), start : Int32, size : Int32) : String?
      j = start
      after_minus = false
      while j < size
        cj = chars[j]
        if cj == '-'
          return "missing flag at position #{j}" if after_minus
          after_minus = true
        elsif "iLmsxua".includes?(cj)
          after_minus = false
        elsif cj == ':' || cj == ')'
          return "missing flag at position #{j}" if after_minus
          return nil
        else
          return "missing flag at position #{j}" if after_minus
          return "missing -, : or ) at position #{j}"
        end
        j += 1
      end
      "missing -, : or ) at position #{size}"
    end

    # The escape at chars[i] == '\\'. Returns {source chars consumed,
    # error?, replacement?} - a replacement only for the two forms
    # Python accepts and PCRE2 does not (\uXXXX, \Uhhhhhhhh), spelled
    # as PCRE2's \x{...}. Positions are the index of the backslash,
    # as re._parser reports them.
    private def self.check_escape(chars : Array(Char), i : Int32, in_class : Bool) : {Int32, String?, String?}
      if i + 1 >= chars.size
        return {1, "bad escape (end of pattern) at position #{i}", nil}
      end
      c = chars[i + 1]
      # \0-\7 are octal escapes/group references in both engines; \8
      # and \9 differ semantically (Python counts groups, PCRE2
      # errors) and stay with PCRE2.
      return {2, nil, nil} if c.ascii_number?
      return {2, nil, nil} unless c.ascii_letter?
      check_letter_escape(chars, i, c, in_class)
    end

    private def self.check_letter_escape(chars : Array(Char), i : Int32, c : Char, in_class : Bool) : {Int32, String?, String?}
      case c
      when 'a', 'b', 'f', 'n', 'r', 't', 'v', 'd', 'D', 's', 'S', 'w', 'W'
        {2, nil, nil}
      when 'x'
        check_hex_escape(chars, i, 2, 'x')
      when 'u'
        check_hex_escape(chars, i, 4, 'u')
      when 'U'
        check_hex_escape(chars, i, 8, 'U')
      when 'N'
        check_name_escape(chars, i)
      when 'g'
        check_group_escape(chars, i, in_class)
      when 'A', 'B', 'Z'
        check_anchor_escape(i, c, in_class)
      else
        {2, "bad escape \\#{c} at position #{i}", nil}
      end
    end

    private def self.check_hex_escape(chars : Array(Char), i : Int32, width : Int32, letter : Char) : {Int32, String?, String?}
      hex = hex_run(chars, i + 2, width)
      if hex.size == width
        # \uXXXX/\Uhhhhhhhh are the one escape form Python accepts and
        # PCRE2 does not - spelled as PCRE2's \x{...}.
        replacement = width == 2 ? nil : "\\x{#{hex}}"
        {width + 2, nil, replacement}
      else
        {2, "incomplete escape \\#{letter}#{hex} at position #{i}", nil}
      end
    end

    private def self.check_name_escape(chars : Array(Char), i : Int32) : {Int32, String?, String?}
      if i + 2 < chars.size && chars[i + 2] == '{'
        {2, nil, nil}
      else
        {2, "missing { at position #{i + 2}", nil}
      end
    end

    private def self.check_group_escape(chars : Array(Char), i : Int32, in_class : Bool) : {Int32, String?, String?}
      if !in_class && i + 2 < chars.size && (chars[i + 2] == '<' || chars[i + 2] == '\'')
        {2, nil, nil}
      else
        {2, "bad escape \\g at position #{i}", nil}
      end
    end

    private def self.check_anchor_escape(i : Int32, c : Char, in_class : Bool) : {Int32, String?, String?}
      if in_class
        {2, "bad escape \\#{c} at position #{i}", nil}
      else
        {2, nil, nil}
      end
    end

    private def self.hex_run(chars : Array(Char), from : Int32, limit : Int32) : String
      result = String::Builder.new
      j = from
      while j < chars.size && result.bytesize < limit && "0123456789abcdefABCDEF".includes?(chars[j])
        result << chars[j]
        j += 1
      end
      result.to_s
    end

    # Translated-pattern char index -> original-pattern char index,
    # through the \u/\U rewrites (each maps its whole output span to
    # the source index of its backslash).
    def self.source_index(scan : Scan, translated_char_index : Int32) : Int32
      index = translated_char_index
      if rewrites = scan.rewrites
        rewrites.each do |out_start, out_len, src|
          break if index < out_start
          return src if index < out_start + out_len
          index -= out_len - 1
        end
      end
      index
    end

    # Whether the '}' at chars[close] closes a real {m,n}/ quantifier
    # (used to tell Python's "multiple repeat" from "nothing to
    # repeat" when PCRE2 reports an unusable quantifier after a
    # brace).
    def self.quantifier_brace?(chars : Array(Char), close : Int32) : Bool
      j = close - 1
      seen_digit = false
      while j >= 0 && chars[j].ascii_number?
        seen_digit = true
        j -= 1
      end
      if j >= 0 && chars[j] == ','
        j -= 1
        while j >= 0 && chars[j].ascii_number?
          seen_digit = true
          j -= 1
        end
      end
      j >= 0 && seen_digit && chars[j] == '{' && !(j > 0 && chars[j - 1] == '\\')
    end

    # Full "compile it the way Python would" check: nil when the pattern
    # is valid under Python's own parser AND PCRE2, otherwise the
    # re.error text Python's executor would wrap. Lets a plugin express
    # the scan + compile + translate pipeline as one question instead of
    # repeating its three steps.
    def self.python_error(pattern : String) : String?
      scan = scan(pattern)
      return scan.error if scan.error
      begin
        Regex.new(scan.translated)
        nil
      rescue ex : Regex::Error | ArgumentError
        python_pcre_error(ex.message || "", scan)
      end
    end

    # Translates a PCRE2 compile error (Crystal's wording, " at <byte
    # offset>" suffix) into the re.error text Python's own parser raises
    # for the same pattern, wherever the mapping is exact. PCRE2's
    # offsets count BYTES; Python's re.error positions count CHARACTERS
    # of the pattern as the user wrote it, so the offset goes byte ->
    # translated char -> source char (the \uXXXX/\Uhhhhhhhh rewrites can
    # move it). Cases without an exact mapping keep the PCRE2 wording -
    # still inside the crash wrapper, which is the part users actually
    # script against.
    def self.python_pcre_error(pcre_message : String, scan : Scan) : String
      match = pcre_message.match(/\A(.+) at (\d+)\z/)
      return pcre_message unless match

      text = match[1]
      char_offset = scan.translated.byte_slice(0, match[2].to_i).size
      case text
      when "missing closing parenthesis"                  then missing_paren_error(scan, char_offset)
      when "missing terminating ] for character class"    then unterminated_class_error(scan, char_offset)
      when "unmatched closing parenthesis"                then unbalanced_paren_error(scan, char_offset)
      when "quantifier does not follow a repeatable item" then repeat_error(scan, char_offset)
      when "unrecognized character follows \\"            then bad_escape_error(scan, char_offset)
      when "\\ at end of pattern"                         then end_of_pattern_escape_error(scan, char_offset)
      when "numbers out of order in {} quantifier"        then min_repeat_error(scan, char_offset)
      else                                                     pcre_message
      end
    end

    private def self.missing_paren_error(scan : Scan, char_offset : Int32) : String
      # Python points at the INNERMOST unterminated '(' - "a(b" at 2,
      # "unmatched (" at 10 - which PCRE2's end-of-pattern offset does
      # not carry; the scan tracked the '(' stack instead.
      position = scan.unclosed_paren || char_offset
      "missing ), unterminated subpattern at position #{position}"
    end

    private def self.unterminated_class_error(scan : Scan, char_offset : Int32) : String
      position = scan.open_class_start || char_offset
      "unterminated character set at position #{position}"
    end

    private def self.unbalanced_paren_error(scan : Scan, char_offset : Int32) : String
      # Both engines point at the stray ')' itself.
      "unbalanced parenthesis at position #{source_index(scan, char_offset)}"
    end

    private def self.bad_escape_error(scan : Scan, char_offset : Int32) : String
      backslash = source_index(scan, (char_offset - 1).clamp(0, Int32::MAX))
      offending = scan.translated[char_offset]? || ""
      "bad escape \\#{offending} at position #{backslash}"
    end

    private def self.end_of_pattern_escape_error(scan : Scan, char_offset : Int32) : String
      backslash = source_index(scan, (char_offset - 1).clamp(0, Int32::MAX))
      "bad escape (end of pattern) at position #{backslash}"
    end

    private def self.min_repeat_error(scan : Scan, char_offset : Int32) : String
      chars = scan.translated.chars
      j = char_offset - 1
      while j >= 0 && chars[j]? != '{'
        j -= 1
      end
      d = j + 1
      while d < chars.size && !chars[d].ascii_number?
        d += 1
      end
      position = d < chars.size ? source_index(scan, d) : char_offset
      "min repeat greater than max repeat at position #{position}"
    end

    # PCRE2 collapses Python's two quantifier errors into one message;
    # the shape of the char before the quantifier tells them apart the
    # way Python's parser does (a quantifier right after a quantifier is
    # "multiple repeat" - except a trailing ? (lazy) or + (possessive,
    # which PCRE2 accepts outright so it never reaches here) - anything
    # else non-repeatable is "nothing to repeat").
    private def self.repeat_error(scan : Scan, char_offset : Int32) : String
      chars = scan.translated.chars
      source = source_index(scan, char_offset)
      if char_offset.zero?
        return "nothing to repeat at position #{source}"
      end
      prev = chars[char_offset - 1]
      if prev.in?('*', '+', '?') || (prev == '}' && quantifier_brace?(chars, char_offset - 1))
        "multiple repeat at position #{source}"
      else
        "nothing to repeat at position #{source}"
      end
    end
  end
end
