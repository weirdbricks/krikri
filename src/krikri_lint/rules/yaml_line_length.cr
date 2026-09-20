module Krikri
  module Lint
    # Upstream parity: ansible-lint's yaml[line-length] (delegated to
    # yamllint upstream; severity MEDIUM since yamllint's line-length
    # runs at error level, tags formatting/yaml). Max 160 chars, the
    # value in ansible-lint's bundled .yamllint.
    class YamlLineLengthRule < Rule
      MAX_LENGTH = 160

      def id : String
        "yaml[line-length]"
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
        line_number = 1
        File.each_line(file.path) do |line|
          line = line.chomp
          if line.size > MAX_LENGTH
            violations << Violation.new(
              file.path, line_number, 0, id, severity,
              "Line too long (#{line.size} > #{MAX_LENGTH} characters)"
            )
          end
          line_number += 1
        end
      end
    end
  end
end
