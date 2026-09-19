module Krikri
  module Lint
    # Reports files that fail to parse as violations, the way
    # ansible-lint's syntax-check does. Parse errors are detected during
    # PositionedFile.load; this rule just surfaces them.
    class SyntaxCheckRule < Rule
      def id : String
        "syntax-check"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core", "unskippable"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        if (err = file.parse_error)
          violations << Violation.new(file.path, err.line, err.column, id, severity, "syntax error: #{err.message}")
        elsif file.root.nil?
          violations << Violation.new(file.path, 1, 1, id, severity, "empty file")
        end
      end
    end
  end
end
