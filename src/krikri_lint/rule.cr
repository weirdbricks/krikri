module Krikri
  module Lint
    abstract class Rule
      abstract def id : String
      abstract def severity : Severity
      abstract def tags : Array(String)
      abstract def applies_to : Array(FileType)
      abstract def check(file : PositionedFile, violations : Array(Violation))

      def applies?(file : PositionedFile) : Bool
        applies_to.includes?(file.file_type)
      end

      # Autofix support, mirroring upstream's TransformMixin: a rule
      # opts in by overriding fixable? (and carrying the "autofix" tag
      # like upstream does) and implementing fix. fix must only make
      # line-local edits through the FixBuffer (replace spans within
      # existing lines, delete whole lines, add the final newline);
      # returning true marks the violation fixed so the CLI drops it
      # from the report.
      def fixable? : Bool
        false
      end

      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        false
      end
    end
  end
end
