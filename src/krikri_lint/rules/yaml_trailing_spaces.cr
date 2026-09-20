module Krikri
  module Lint
    # Upstream parity: yaml[trailing-spaces] (from yamllint, as
    # configured by ansible-lint's bundled .yamllint). Reports each line
    # ending in whitespace at that line, no column.
    class YamlTrailingSpacesRule < Rule
      def id : String
        "yaml[trailing-spaces]"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["autofix", "formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def fixable? : Bool
        true
      end

      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        line = buffer.line_text(violation.line) || return false
        stripped = line.rstrip(" \t")
        return false if stripped == line
        buffer.replace_span(violation.line, stripped.size + 1,
          line.size - stripped.size, "")
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless File.exists?(file.path)
        line_number = 1
        File.each_line(file.path) do |line|
          stripped = line.chomp
          if stripped != stripped.rstrip
            violations << Violation.new(file.path, line_number, 0, id,
              severity, "Trailing spaces")
          end
          line_number += 1
        end
      end
    end
  end
end
