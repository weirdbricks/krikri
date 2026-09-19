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
    end
  end
end
