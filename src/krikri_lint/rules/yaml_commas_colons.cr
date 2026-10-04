require "../yaml_tokens"

module Krikri
  module Lint
    # Shared spacing-gap checks for the token-level yamllint rules, so
    # yaml[commas] and yaml[colons] agree on pyyaml's spaces_before /
    # spaces_after semantics: both only compare tokens on the same line,
    # and both discard a previous token that ended at a line start.
    module YamlSpacing
      extend self

      def check_commas(file : PositionedFile, id : String, sev : Severity, &) : Nil
        tokens = YamlTokens.scan(file)
        tokens.each_with_index do |token, index|
          next unless token.kind.flow_entry?
          prev = index > 0 ? tokens[index - 1] : nil
          nxt = tokens[index + 1]?
          line = token.start_line
          # A comma on its own line (the previous entry ended on an
          # earlier one) counts as a space before it, as pyyaml does.
          if prev && prev.end_line < token.start_line
            yield Violation.new(file.path, line, 0, id, sev,
              "Too many spaces before comma")
          elsif gap_after(prev, token) > MAX_SPACES_BEFORE_COMMA
            yield Violation.new(file.path, line, 0, id, sev,
              "Too many spaces before comma")
          end
          next unless nxt && token.end_line == nxt.start_line
          spaces = nxt.start_col - token.end_col
          if spaces > MAX_SPACES_AFTER_COMMA
            yield Violation.new(file.path, line, 0, id, sev,
              "Too many spaces after comma")
          elsif spaces < MIN_SPACES_AFTER_COMMA
            yield Violation.new(file.path, line, 0, id, sev,
              "Too few spaces after comma")
          end
        end
      end

      def check_colons(file : PositionedFile, id : String, sev : Severity, &) : Nil
        tokens = YamlTokens.scan(file)
        tokens.each_with_index do |token, index|
          prev = index > 0 ? tokens[index - 1] : nil
          nxt = tokens[index + 1]?
          next unless token.kind.value? || token.kind.key?
          next if alias_key?(token, prev)
          if token.kind.value? && gap_after(prev, token) > MAX_SPACES_BEFORE_COLON
            yield Violation.new(file.path, token.start_line, 0, id, sev,
              "Too many spaces before colon")
          end
          next unless nxt && token.end_line == nxt.start_line
          next if nxt.start_col - token.end_col <= MAX_SPACES_AFTER_COLON
          message = token.kind.key? ? "Too many spaces after question mark" : "Too many spaces after colon"
          yield Violation.new(file.path, token.start_line, 0, id, sev, message)
        end
      end

      # `*alias:value` (no space before the colon) is an alias used as
      # a key, which pyyaml deliberately exempts from the check.
      private def alias_key?(token : YamlTokens::Token, prev : YamlTokens::Token?) : Bool
        return false unless token.kind.value?
        return false if prev.nil?
        prev.kind.alias? && prev.end_line == token.start_line &&
          prev.end_col == token.start_col
      end

      # Spaces between a token and the one before it on the same line.
      # A previous token that ended at a line start is ignored, as
      # pyyaml's spaces_before does. -1 means "not comparable".
      private def gap_after(prev : YamlTokens::Token?, token : YamlTokens::Token) : Int32
        return -1 unless prev && prev.end_line == token.start_line && prev.end_col > 0
        token.start_col - prev.end_col
      end

      MAX_SPACES_BEFORE_COMMA = 0
      MIN_SPACES_AFTER_COMMA  = 1
      MAX_SPACES_AFTER_COMMA  = 1
      MAX_SPACES_BEFORE_COLON = 0
      MAX_SPACES_AFTER_COLON  = 1
    end

    # Upstream parity: yaml[commas] (from yamllint, as configured by
    # ansible-lint's bundled .yamllint which extends yamllint's
    # defaults: max-spaces-before 0, min-spaces-after 1, max-spaces-after
    # 1; error level, so MEDIUM here). Only flow-sequence/flow-mapping
    # entry indicators are checked - a comma in block context is scalar
    # text, not a token.
    class YamlCommasRule < Rule
      def id : String
        "yaml[commas]"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Upstream's yaml transform is a documented no-op (the
      # reformatting happens in the data dumper), so it never marks a
      # match fixed; every yaml[*] match gets a "not applied" ERROR.
      def transformable? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless file.root
        YamlSpacing.check_commas(file, id, severity) { |v| violations << v }
      end
    end

    # Upstream parity: yaml[colons] (from yamllint, as configured by
    # ansible-lint's bundled .yamllint: max-spaces-before 0,
    # max-spaces-after 1; error level, so MEDIUM here). Checks the
    # value indicator ":" and the explicit-key indicator "?".
    class YamlColonsRule < Rule
      def id : String
        "yaml[colons]"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless file.root
        YamlSpacing.check_colons(file, id, severity) { |v| violations << v }
      end
    end
  end
end
