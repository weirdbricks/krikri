module Krikri
  module Lint
    # Upstream parity: yaml[new-line-at-end-of-file] (from yamllint
    # defaults; error level, MEDIUM here). Fires when the file's last
    # line has content and no trailing newline, at that line with no
    # column: "No new line character at the end of file".
    class YamlNewLineAtEndOfFileRule < Rule
      def id : String
        "yaml[new-line-at-end-of-file]"
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
        return unless File.exists?(file.path)
        content = File.read(file.path)
        return if content.empty? || content.ends_with?('\n')
        violations << Violation.new(file.path, content.count('\n') + 1, 0, id,
          severity, "No new line character at the end of file")
      end
    end
  end
end
