module Krikri
  module Lint
    # Minimal YAML token scanner, used by the token-level yamllint rules
    # (yaml[commas], yaml[colons]). Those rules only compare the
    # whitespace gap between adjacent tokens, so the scanner emits just
    # enough of a token stream - the punctuation tokens themselves plus
    # whatever scalar/indicator token serves as their prev/next.
    #
    # It follows pyyaml's scanner (the one yamllint runs on) for the
    # decisions that change token boundaries: quote spans, comment
    # starts, flow-context indicators, and where a plain scalar ends.
    # Lines that are continuation content of a multi-line scalar are
    # skipped wholesale (the parse tree already knows which ones).
    module YamlTokens
      extend self

      enum Kind
        VALUE
        FLOW_ENTRY
        KEY
        ALIAS
        OTHER
      end

      record Token,
        kind : Kind,
        start_line : Int32,
        start_col : Int32,
        end_line : Int32,
        end_col : Int32 do
        def zero_width_at_line_start? : Bool
          start_col == 0 && end_col == 0
        end
      end

      WHITESPACE      = [' ', '\t']
      FLOW_INDICATORS = [',', '?', '[', ']', '{', '}']

      def scan(file : PositionedFile) : Array(Token)
        Scanner.new(file).scan
      end

      # Line/column bookkeeping is by character, matching pyyaml's
      # column semantics (what yamllint reports and compares).
      private class Scanner
        getter chars : Array(Char)
        getter skip_lines : Set(Int32)

        def initialize(file : PositionedFile)
          content = File.exists?(file.path) ? File.read(file.path) : ""
          @chars = content.chars
          @skip_lines = YamlText.scalar_continuation_lines(file)
        end

        def scan : Array(Token)
          tokens = [] of Token
          pos = 0
          line = 1
          col = 0
          flow = 0
          while pos < @chars.size
            if col == 0 && skip_line?(line)
              pos = skip_to_eol(pos)
              # consume the line break too, otherwise the same line is
              # re-detected as skippable and the scan never advances
              if pos < @chars.size && @chars[pos] == '\n'
                pos += 1
                line += 1
              end
              next
            end
            ch = @chars[pos]
            if ch == '\n'
              pos += 1
              line += 1
              col = 0
              next
            elsif ch == '\r'
              pos += 1
              next
            elsif WHITESPACE.includes?(ch)
              pos += 1
              col += 1
              next
            elsif comment_start?(pos, col)
              pos = skip_to_eol(pos)
              next
            end

            start_line = line
            start_col = col
            kind = Kind::OTHER
            case
            when ch == '\'' || ch == '"'
              pos, line, col = scan_quoted(pos, line, col, ch)
            when ch == '[' || ch == '{'
              flow += 1
              pos += 1
              col += 1
            when ch == ']' || ch == '}'
              flow -= 1 if flow > 0
              pos += 1
              col += 1
            when ch == ',' && flow > 0
              kind = Kind::FLOW_ENTRY
              pos += 1
              col += 1
            when ch == ':' && (flow > 0 || space_or_eol?(pos + 1))
              kind = Kind::VALUE
              pos += 1
              col += 1
            when ch == '?' && (flow > 0 || space_or_eol?(pos + 1))
              kind = Kind::KEY
              pos += 1
              col += 1
            when ch == '*'
              kind = Kind::ALIAS
              pos, col = scan_plain(pos + 1, col + 1, flow)
            when ch == '&' || ch == '!'
              pos, col = scan_plain(pos + 1, col + 1, flow)
            else
              pos, col = scan_plain(pos, col, flow)
            end
            tokens << Token.new(kind, start_line, start_col, line, col)
          end
          tokens
        end

        private def skip_line?(line : Int32) : Bool
          skip_lines.includes?(line)
        end

        private def skip_to_eol(pos : Int32) : Int32
          while pos < @chars.size && @chars[pos] != '\n'
            pos += 1
          end
          pos
        end

        private def space_or_eol?(pos : Int32) : Bool
          ch = @chars[pos]?
          ch.nil? || ch == '\0' || WHITESPACE.includes?(ch) || ch == '\n' || ch == '\r'
        end

        private def comment_start?(pos : Int32, col : Int32) : Bool
          return false unless @chars[pos] == '#'
          col == 0 || preceded_by_space?(pos)
        end

        private def preceded_by_space?(pos : Int32) : Bool
          return false if pos == 0
          WHITESPACE.includes?(@chars[pos - 1])
        end

        # A plain scalar runs until whitespace, a comment, a `:` that is
        # followed by whitespace (or, in flow context, an indicator), or -
        # in flow context only - one of `,?[]{}`.
        private def scan_plain(pos : Int32, col : Int32, flow : Int32) : {Int32, Int32}
          while pos < @chars.size
            ch = @chars[pos]
            break if ch == '\n' || ch == '\r' || WHITESPACE.includes?(ch)
            break if ch == '#' && (col == 0 || preceded_by_space?(pos))
            if ch == ':'
              next_ch = @chars[pos + 1]?
              break if next_ch.nil? || WHITESPACE.includes?(next_ch) ||
                       next_ch == '\n' || next_ch == '\r'
              break if flow > 0 && FLOW_INDICATORS.includes?(next_ch)
            end
            break if flow > 0 && FLOW_INDICATORS.includes?(ch)
            pos += 1
            col += 1
          end
          {pos, col}
        end

        # Quoted scalars may span lines; `''` inside a single-quoted one
        # is an escaped quote, and a double-quoted one honours backslash
        # escapes.
        private def scan_quoted(pos : Int32, line : Int32, col : Int32, quote : Char) : {Int32, Int32, Int32}
          pos += 1
          col += 1
          while pos < @chars.size
            ch = @chars[pos]
            if ch == '\n'
              pos += 1
              line += 1
              col = 0
              next
            end
            if quote == '"' && ch == '\\'
              pos += 1
              col += 1
              if pos < @chars.size && @chars[pos] == '\n'
                pos += 1
                line += 1
                col = 0
              else
                pos += 1
                col += 1
              end
              next
            end
            pos += 1
            col += 1
            if ch == quote
              if quote == '\'' && @chars[pos]? == '\''
                pos += 1
                col += 1
                next
              end
              break
            end
          end
          {pos, line, col}
        end
      end
    end
  end
end
