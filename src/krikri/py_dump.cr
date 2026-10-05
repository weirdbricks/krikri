require "json"

module Krikri
  # Byte-exact ports of the two serializers behind ansible's to_json /
  # to_nice_json / to_yaml / to_nice_yaml filters: Python's json.dumps and
  # PyYAML's yaml.dump (AnsibleDumper, allow_unicode=True). Verified against
  # ansible-core 2.19.11 output for scalars, nested collections, quoting
  # edge cases, flow/block selection and 80-column wrapping.
  module PyDump
    # ---- json.dumps -----------------------------------------------------
    def self.json(value : JSON::Any, indent : Int32? = nil, sort_keys : Bool = false) : String
      String.build { |io| write_json(io, value, indent, sort_keys, 0) }
    end

    private def self.write_json(io : IO, value : JSON::Any, indent : Int32?, sort_keys : Bool, level : Int32) : Nil
      case raw = value.raw
      when Nil    then io << "null"
      when Bool   then io << (raw ? "true" : "false")
      when Int    then io << raw.to_s
      when Float  then io << py_float_repr(raw)
      when String then json_string(io, raw)
      when Array  then write_json_array(io, raw, indent, sort_keys, level)
      when Hash   then write_json_object(io, raw, indent, sort_keys, level)
      end
    end

    private def self.write_json_array(io : IO, raw : Array(JSON::Any), indent : Int32?, sort_keys : Bool, level : Int32) : Nil
      if raw.empty?
        io << "[]"
        return
      end

      unless indent
        io << "["
        raw.each_with_index do |item, idx|
          io << ", " if idx > 0
          write_json(io, item, indent, sort_keys, level + 1)
        end
        io << "]"
        return
      end

      io << "[\n"
      raw.each_with_index do |item, idx|
        io << " " * (indent * (level + 1))
        write_json(io, item, indent, sort_keys, level + 1)
        io << (idx == raw.size - 1 ? "\n" : ",\n")
      end
      io << " " * (indent * level) << "]"
    end

    private def self.write_json_object(io : IO, raw : Hash(String, JSON::Any), indent : Int32?, sort_keys : Bool, level : Int32) : Nil
      if raw.empty?
        io << "{}"
        return
      end

      pairs = raw.to_a
      pairs = pairs.sort_by { |(k, _)| k } if sort_keys

      unless indent
        io << "{"
        pairs.each_with_index do |(k, v), idx|
          io << ", " if idx > 0
          json_string(io, k)
          io << ": "
          write_json(io, v, indent, sort_keys, level + 1)
        end
        io << "}"
        return
      end

      io << "{\n"
      pairs.each_with_index do |(k, v), idx|
        io << " " * (indent * (level + 1))
        json_string(io, k)
        io << ": "
        write_json(io, v, indent, sort_keys, level + 1)
        io << (idx == pairs.size - 1 ? "\n" : ",\n")
      end
      io << " " * (indent * level) << "}"
    end

    # json.dumps(ensure_ascii=True) string encoding
    private def self.json_string(io : IO, text : String) : Nil
      io << '"'
      text.each_char do |char|
        case char
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\n' then io << "\\n"
        when '\r' then io << "\\r"
        when '\t' then io << "\\t"
        when '\b' then io << "\\b"
        when '\f' then io << "\\f"
        else
          code = char.ord
          if code < 0x20
            io << "\\u" << code.to_s(16).rjust(4, '0')
          elsif code > 0x7e && code != 0x7f
            if code > 0xFFFF
              v = code - 0x10000
              io << "\\u" << (0xD800 | (v >> 10)).to_s(16).rjust(4, '0')
              io << "\\u" << (0xDC00 | (v & 0x3FF)).to_s(16).rjust(4, '0')
            else
              io << "\\u" << code.to_s(16).rjust(4, '0')
            end
          else
            io << char
          end
        end
      end
      io << '"'
    end

    # Python repr(float)
    def self.py_float_repr(value : Float64) : String
      return "NaN" if value.nan?
      return (value > 0 ? "Infinity" : "-Infinity") if value.infinite?
      text = value.to_s
      if text.includes?('e')
        mantissa, exponent = text.split('e', 2)
        mantissa = mantissa.sub(/\.0\z/, "")
        sign = exponent.starts_with?('-') ? "-" : "+"
        digits = exponent.lstrip("+-").rjust(2, '0')
        return "#{mantissa}e#{sign}#{digits}"
      end
      text
    end

    # ---- yaml.dump ------------------------------------------------------
    # default_flow_style: nil (PyYAML default: flow for scalar-only
    # collections), false (block everywhere, to_nice_yaml).
    def self.yaml(value : JSON::Any, indent : Int32 = 2, default_flow_style : Bool? = nil, sort_keys : Bool = true, width : Int32 = 80) : String
      YamlEmitter.new(indent, default_flow_style, sort_keys, width).dump(value)
    end

    class YamlEmitter
      @io = IO::Memory.new
      @column = 0
      @whitespace = true
      @indention = true
      @indent : Int32? = nil
      @indents = [] of Int32?
      @flow_level = 0
      @root_context = false
      @sequence_context = false
      @mapping_context = false
      @simple_key_context = false
      @open_ended = false

      def initialize(@best_indent : Int32, @default_flow : Bool?, @sort_keys : Bool, @best_width : Int32)
        @best_indent = 2 unless 1 < @best_indent && @best_indent < 10
        @best_width = 80 unless @best_width > @best_indent * 2
      end

      def dump(value : JSON::Any) : String
        emit_node(value, root: true)
        write_indent
        if @open_ended
          @io << "..."
          @column += 3
          write_indent
        end
        @io.to_s
      end

      # ---- node dispatch -------------------------------------------------
      private def emit_node(value : JSON::Any, root : Bool = false, sequence : Bool = false, mapping : Bool = false, simple_key : Bool = false) : Nil
        @root_context = root
        @sequence_context = sequence
        @mapping_context = mapping
        @simple_key_context = simple_key

        case raw = value.raw
        when Array
          if @flow_level > 0 || flow_style?(value) || raw.empty?
            emit_flow_sequence(raw)
          else
            emit_block_sequence(raw)
          end
        when Hash
          if @flow_level > 0 || flow_style?(value) || raw.empty?
            emit_flow_mapping(raw)
          else
            emit_block_mapping(raw)
          end
        else
          emit_scalar(value)
        end
      end

      # PyYAML represent_sequence/mapping: with default_flow_style None a
      # collection is flow iff every item (and key) is a plain scalar node.
      private def flow_style?(value : JSON::Any) : Bool
        flow = @default_flow
        return flow unless flow.nil?

        case raw = value.raw
        when Array then raw.all? { |item| scalar?(item) }
        when Hash  then raw.all? { |(_, item)| scalar?(item) }
        else            false
        end
      end

      private def scalar?(value : JSON::Any) : Bool
        !(value.raw.is_a?(Array) || value.raw.is_a?(Hash))
      end

      # ---- collections ---------------------------------------------------
      private def emit_flow_sequence(items : Array(JSON::Any)) : Nil
        write_indicator("[", true, whitespace: true)
        increase_indent(flow: true)
        @flow_level += 1
        items.each_with_index do |item, idx|
          write_indicator(",", false) if idx > 0
          write_indent if @column > @best_width
          emit_node(item, sequence: true)
        end
        @flow_level -= 1
        @indent = @indents.pop
        write_indicator("]", false)
      end

      private def emit_flow_mapping(hash : Hash(String, JSON::Any)) : Nil
        write_indicator("{", true, whitespace: true)
        increase_indent(flow: true)
        @flow_level += 1
        pairs(hash).each_with_index do |(key, item), idx|
          write_indicator(",", false) if idx > 0
          write_indent if @column > @best_width
          emit_node(JSON::Any.new(key), mapping: true, simple_key: true)
          write_indicator(":", false)
          emit_node(item, mapping: true)
        end
        @flow_level -= 1
        @indent = @indents.pop
        write_indicator("}", false)
      end

      private def emit_block_sequence(items : Array(JSON::Any)) : Nil
        indentless = @mapping_context && !@indention
        increase_indent(flow: false, indentless: indentless)
        items.each do |item|
          write_indent
          write_indicator("-", true, indention: true)
          emit_node(item, sequence: true)
        end
        @indent = @indents.pop
      end

      private def emit_block_mapping(hash : Hash(String, JSON::Any)) : Nil
        increase_indent(flow: false)
        pairs(hash).each do |(key, item)|
          write_indent
          emit_node(JSON::Any.new(key), mapping: true, simple_key: true)
          write_indicator(":", false)
          emit_node(item, mapping: true)
        end
        @indent = @indents.pop
      end

      private def pairs(hash : Hash(String, JSON::Any)) : Array({String, JSON::Any})
        list = hash.to_a
        list = list.sort_by { |(key, _)| key } if @sort_keys
        list
      end

      # ---- scalars -------------------------------------------------------
      private def emit_scalar(value : JSON::Any) : Nil
        increase_indent(flow: true)
        text, implicit_plain = scalar_text(value)
        analysis = analyze(text)
        style = choose_style(analysis, implicit_plain)
        split = !@simple_key_context
        case style
        when '"'  then write_double_quoted(text, split)
        when '\'' then write_single_quoted(text, split)
        else           write_plain(text, split)
        end
        @indent = @indents.pop
      end

      # {text, plain-allowed-by-resolver}. Non-string scalars always resolve
      # implicitly; a string only if its plain form would resolve back to str.
      private def scalar_text(value : JSON::Any) : {String, Bool}
        case raw = value.raw
        when Nil    then {"null", true}
        when Bool   then {raw ? "true" : "false", true}
        when Int    then {raw.to_s, true}
        when Float  then {float_scalar(raw), true}
        when String then {raw, string_resolves_to_str?(raw)}
        else             {value.to_s, true}
        end
      end

      private def float_scalar(value : Float64) : String
        return ".nan" if value.nan?
        return (value > 0 ? ".inf" : "-.inf") if value.infinite?
        text = PyDump.py_float_repr(value).downcase
        text = text.sub("e", ".0e") if !text.includes?('.') && text.includes?('e')
        text
      end

      BOOL_RE  = /\A(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)\z/
      NULL_RE  = /\A(?:~|null|Null|NULL|)\z/
      INT_RE   = /\A(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z/
      FLOAT_RE = /\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z/
      TIME_RE  = /\A(?:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?)\z/

      private def string_resolves_to_str?(text : String) : Bool
        return false if text.matches?(BOOL_RE) || text.matches?(NULL_RE) || text.matches?(INT_RE)
        return false if text.matches?(FLOAT_RE) || text.matches?(TIME_RE)
        return false if text == "<<" || text == "="
        true
      end

      private record Analysis, empty : Bool, multiline : Bool, allow_flow_plain : Bool, allow_block_plain : Bool, allow_single : Bool, allow_double : Bool

      private def analyze(text : String) : Analysis
        return Analysis.new(true, false, false, true, true, true) if text.empty?

        scan = ScalarScan.new
        if text.starts_with?("---") || text.starts_with?("...")
          scan.flow_indicators = true
          scan.block_indicators = true
        end
        scan_chars(text, scan)

        allowed_styles(scan)
      end

      # The flags analyze's per-character walk accumulates, in their
      # own object so analyze itself stays a straight match of PyYAML's
      # analyze_scalar instead of a dozen locals.
      private class ScalarScan
        property? flow_indicators = false
        property? block_indicators = false
        property? line_breaks = false
        property? special = false
        property? leading_space = false
        property? leading_break = false
        property? trailing_space = false
        property? trailing_break = false
        property? break_space = false
        property? space_break = false
        property? previous_space = false
        property? previous_break = false

        def scan_indicators(ch : Char, index : Int32, preceded_by_ws : Bool, followed_by_ws : Bool) : Nil
          if index == 0
            scan_leading_indicators(ch, followed_by_ws)
          else
            scan_inner_indicators(ch, preceded_by_ws, followed_by_ws)
          end
        end

        # The first character of a scalar: the full indicator set, plus
        # the leading '?'/':'/- that only count at the start.
        private def scan_leading_indicators(ch : Char, followed_by_ws : Bool) : Nil
          if "# []{}&*!|>'\"%@`".includes?(ch)
            @flow_indicators = @block_indicators = true
          end
          if ch == '?' || ch == ':'
            @flow_indicators = true
            @block_indicators = true if followed_by_ws
          end
          if ch == '-' && followed_by_ws
            @flow_indicators = @block_indicators = true
          end
        end

        # Every later character: only ',?[]{}', a followed-by-space ':'
        # and a preceded-by-space '#' count.
        private def scan_inner_indicators(ch : Char, preceded_by_ws : Bool, followed_by_ws : Bool) : Nil
          @flow_indicators = true if ",?[]{}".includes?(ch)
          if ch == ':'
            @flow_indicators = true
            @block_indicators = true if followed_by_ws
          end
          if ch == '#' && preceded_by_ws
            @flow_indicators = @block_indicators = true
          end
        end

        def scan_printable(ch : Char) : Nil
          @line_breaks = true if line_break?(ch)
          unless ch == '\n' || (' ' <= ch && ch <= '~')
            @special = true unless printable_unicode?(ch.ord)
          end
        end

        def scan_whitespace(ch : Char, index : Int32, size : Int32) : Nil
          if ch == ' '
            @leading_space = true if index == 0
            @trailing_space = true if index == size - 1
            @break_space = true if @previous_break
            @previous_space = true
            @previous_break = false
          elsif line_break?(ch)
            @leading_break = true if index == 0
            @trailing_break = true if index == size - 1
            @space_break = true if @previous_space
            @previous_space = false
            @previous_break = true
          else
            @previous_space = false
            @previous_break = false
          end
        end

        private def line_break?(ch : Char) : Bool
          ch == '\n' || ch == '\u0085' || ch == ' ' || ch == ' '
        end

        private def printable_unicode?(code : Int32) : Bool
          (code == 0x85 || (0xA0 <= code && code <= 0xD7FF) || (0xE000 <= code && code <= 0xFFFD) || (0x10000 <= code && code < 0x10FFFF)) && code != 0xFEFF
        end
      end

      # PyYAML's analyze_scalar walk over one scalar's characters.
      private def scan_chars(text : String, scan : ScalarScan) : Nil
        chars = text.chars
        preceded_by_ws = true
        followed_by_ws = chars.size == 1 || whitespace_char?(chars[1])
        index = 0

        while index < chars.size
          ch = chars[index]
          scan.scan_indicators(ch, index, preceded_by_ws, followed_by_ws)
          scan.scan_printable(ch)
          scan.scan_whitespace(ch, index, chars.size)
          index += 1
          preceded_by_ws = whitespace_char?(ch)
          followed_by_ws = index + 1 >= chars.size || whitespace_char?(chars[index + 1])
        end
      end

      # Which of plain/single/double styles survive the flags the
      # walk collected (PyYAML's own tail of analyze_scalar).
      private def allowed_styles(scan : ScalarScan) : Analysis
        allow_flow_plain = allow_block_plain = allow_single = allow_double = true
        allow_flow_plain = allow_block_plain = false if scan.leading_space? || scan.leading_break? || scan.trailing_space? || scan.trailing_break?
        allow_flow_plain = allow_block_plain = allow_single = false if scan.break_space?
        allow_flow_plain = allow_block_plain = allow_single = false if scan.space_break? || scan.special?
        allow_flow_plain = allow_block_plain = false if scan.line_breaks?
        allow_flow_plain = false if scan.flow_indicators?
        allow_block_plain = false if scan.block_indicators?
        Analysis.new(false, scan.line_breaks?, allow_flow_plain, allow_block_plain, allow_single, allow_double)
      end

      private def whitespace_char?(ch : Char) : Bool
        ch == '\0' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '\u0085' || ch == ' ' || ch == ' '
      end

      private def choose_style(analysis : Analysis, implicit_plain : Bool) : Char?
        if implicit_plain
          if !(@simple_key_context && (analysis.empty || analysis.multiline)) &&
             ((@flow_level > 0 && analysis.allow_flow_plain) || (@flow_level == 0 && analysis.allow_block_plain))
            return nil
          end
        end
        return '\'' if analysis.allow_single && !(@simple_key_context && analysis.multiline)
        '"'
      end

      # ---- low-level writers (emitter.py) ---------------------------------
      private def increase_indent(flow : Bool = false, indentless : Bool = false) : Nil
        @indents << @indent
        current = @indent
        if current.nil?
          @indent = flow ? @best_indent : 0
        elsif !indentless
          @indent = current + @best_indent
        end
      end

      private def write_indicator(indicator : String, need_whitespace : Bool, whitespace : Bool = false, indention : Bool = false) : Nil
        data = (@whitespace || !need_whitespace) ? indicator : " " + indicator
        @whitespace = whitespace
        @indention = @indention && indention
        @column += data.size
        @open_ended = false
        @io << data
      end

      private def write_indent : Nil
        indent = @indent || 0
        if !@indention || @column > indent || (@column == indent && !@whitespace)
          write_line_break
        end
        if @column < indent
          @whitespace = true
          @io << " " * (indent - @column)
          @column = indent
        end
      end

      private def write_line_break(data : String = "\n") : Nil
        @whitespace = true
        @indention = true
        @column = 0
        @io << data
      end

      # PyYAML's write_plain. The three branch helpers hold the chunk
      # loop's own logic so the loop itself stays readable; each returns
      # the new start offset for the next chunk.
      private def write_plain(text : String, split : Bool) : Nil
        @open_ended = true if @root_context
        return if text.empty?

        unless @whitespace
          @column += 1
          @io << ' '
        end
        @whitespace = false
        @indention = false
        chars = text.chars
        spaces = breaks = false
        start = 0
        idx = 0
        while idx <= chars.size
          ch = idx < chars.size ? chars[idx] : nil
          start = if spaces
                    ch == ' ' ? start : plain_spaces_flush(chars, start, idx, split)
                  elsif breaks
                    plain_breaks_flush(chars, start, idx, ch)
                  else
                    plain_run_flush(chars, start, idx, ch)
                  end
          if ch
            spaces = ch == ' '
            breaks = line_break?(ch)
          end
          idx += 1
        end
      end

      # A plain scalar's run of spaces, ended: either the wrap point
      # (write_indent) or the characters themselves.
      private def plain_spaces_flush(chars : Array(Char), start : Int32, idx : Int32, split : Bool) : Int32
        if start + 1 == idx && @column > @best_width && split
          write_indent
          @whitespace = false
          @indention = false
        else
          write_run(chars, start, idx)
        end
        idx
      end

      # A plain scalar's run of line breaks, ended: each break is
      # re-emitted in the form PyYAML uses, then the indent.
      private def plain_breaks_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?) : Int32
        return start if ch && line_break?(ch)
        write_line_break if chars[start] == '\n'
        write_breaks(chars[start...idx])
        write_indent
        @whitespace = false
        @indention = false
        idx
      end

      # A plain scalar's run of ordinary characters, ended at the next
      # space, line break or the end of the scalar.
      private def plain_run_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?) : Int32
        return start unless ch.nil? || ch == ' ' || line_break?(ch)
        write_run(chars, start, idx)
        idx
      end

      # PyYAML's write_single_quoted, which additionally doubles every
      # literal quote it passes.
      private def write_single_quoted(text : String, split : Bool) : Nil
        write_indicator("'", true)
        chars = text.chars
        spaces = breaks = false
        start = 0
        idx = 0
        while idx <= chars.size
          ch = idx < chars.size ? chars[idx] : nil
          start = if spaces
                    ch && ch == ' ' ? start : single_spaces_flush(chars, start, idx, ch, split)
                  elsif breaks
                    single_breaks_flush(chars, start, idx, ch)
                  else
                    single_run_flush(chars, start, idx, ch)
                  end
          if ch == '\''
            @column += 2
            @io << "''"
            start = idx + 1
          end
          if ch
            spaces = ch == ' '
            breaks = line_break?(ch)
          end
          idx += 1
        end
        write_indicator("'", false)
      end

      private def single_spaces_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?, split : Bool) : Int32
        return start if ch && ch == ' '
        if start + 1 == idx && @column > @best_width && split && start != 0 && idx != chars.size
          write_indent
        else
          write_run(chars, start, idx)
        end
        idx
      end

      private def single_breaks_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?) : Int32
        return start if ch && line_break?(ch)
        write_line_break if chars[start] == '\n'
        write_breaks(chars[start...idx])
        write_indent
        idx
      end

      private def single_run_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?) : Int32
        return start unless ch.nil? || ch == ' ' || line_break?(ch) || ch == '\''
        return start if start >= idx
        write_run(chars, start, idx)
        idx
      end

      ESCAPES = {
        '\0' => "0", '\a' => "a", '\b' => "b", '\t' => "t", '\n' => "n", '\v' => "v",
        '\f' => "f", '\r' => "r", '\e' => "e", '"' => "\"", '\\' => "\\",
        '\u0085' => "N", ' ' => "_", ' ' => "L", ' ' => "P",
      }

      # PyYAML's write_double_quoted.
      private def write_double_quoted(text : String, split : Bool) : Nil
        write_indicator("\"", true)
        chars = text.chars
        start = idx = 0
        while idx <= chars.size
          ch = idx < chars.size ? chars[idx] : nil
          start = double_escape_flush(chars, start, idx, ch)
          start = double_split_flush(chars, start, idx, ch, split)
          idx += 1
        end
        write_indicator("\"", false)
      end

      # The escape/flush half of the double-quoted writer's loop: the
      # run of ordinary characters before a character that needs an
      # escape, then the escape itself.
      private def double_escape_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?) : Int32
        code = ch.try(&.ord) || 0
        return start unless double_escape_needed?(ch, code)
        if start < idx
          write_run(chars, start, idx)
          start = idx
        end
        if ch
          data = escape_data(ch, code)
          @column += data.size
          @io << data
          start = idx + 1
        end
        start
      end

      # The line-splitting half: a backslash continuation when the line
      # has run past the wrap width.
      private def double_split_flush(chars : Array(Char), start : Int32, idx : Int32, ch : Char?, split : Bool) : Int32
        return start unless 0 < idx && idx < chars.size - 1 && (ch == ' ' || start >= idx) && @column + (idx - start) > @best_width && split
        data = chars[start...idx].join + "\\"
        start = idx if start < idx
        @column += data.size
        @io << data
        write_indent
        @whitespace = false
        @indention = false
        if start < chars.size && chars[start] == ' '
          @column += 1
          @io << "\\"
        end
        start
      end

      private def double_escape_needed?(ch : Char?, code : Int32) : Bool
        return true if ch.nil? || ch == '"' || ch == '\\' || line_break?(ch) || ch == '\uFEFF'
        !double_printable?(ch, code)
      end

      # PyYAML's own "printable" test: everything outside the escape set
      # and outside the BMP-representable ranges goes out as \\x/\\u/\\U.
      private def double_printable?(ch : Char, code : Int32) : Bool
        ch == '\n' || (' ' <= ch && ch <= '~') || (code >= 0xA0 && code <= 0xD7FF) || (code >= 0xE000 && code <= 0xFFFD) || code >= 0x10000
      end

      private def escape_data(ch : Char, code : Int32) : String
        if ESCAPES.has_key?(ch)
          "\\" + ESCAPES[ch]
        elsif code <= 0xFF
          "\\x" + code.to_s(16).upcase.rjust(2, '0')
        elsif code <= 0xFFFF
          "\\u" + code.to_s(16).upcase.rjust(4, '0')
        else
          "\\U" + code.to_s(16).upcase.rjust(8, '0')
        end
      end

      # ---- shared low-level chunk writers --------------------------------
      private def write_run(chars : Array(Char), start : Int32, idx : Int32) : Nil
        data = chars[start...idx].join
        @column += data.size
        @io << data
      end

      # PyYAML writes each line break in a run back out in its own form
      # (a bare \n first when the run started with one, then the others
      # verbatim).
      private def write_breaks(run : Array(Char)) : Nil
        run.each { |line_break| line_break == '\n' ? write_line_break : write_line_break(line_break.to_s) }
      end

      # The four characters YAML treats as line breaks.
      private def line_break?(ch : Char) : Bool
        ch == '\n' || ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
      end
    end
  end
end
