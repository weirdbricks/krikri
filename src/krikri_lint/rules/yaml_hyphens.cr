module Krikri
  module Lint
    # Upstream parity: yaml[hyphens] (from yamllint defaults:
    # max-spaces-after 1; error level, MEDIUM here). Reported at the
    # block-sequence entry's line with no column:
    # "Too many spaces after hyphen".
    class YamlHyphensRule < Rule
      def id : String
        "yaml[hyphens]"
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
        covered = YamlText.scalar_continuation_lines(file)
        line_number = 0
        YamlText.physical_lines(file.path).each do |line|
          line_number += 1
          next if covered.includes?(line_number)
          scan_line(file, line, line_number, violations)
        end
      end

      # A '-' is a block-sequence entry indicator when it starts the
      # line's content or follows another entry indicator in a nested
      # "- - item" chain, and is followed by whitespace. The gap to the
      # next token on the same line must be at most one space; a comment
      # or end of line after the hyphen means the item continues on the
      # next line, which is not checked (same as upstream).
      private def scan_line(file : PositionedFile, line : String, line_number : Int32, violations : Array(Violation)) : Nil
        pos = indent_end(line)
        while entry_hyphen?(line, pos)
          j = content_index(line, pos + 1)
          break if j.nil? || line[j] == '#'
          report_gap(file, line_number, j - (pos + 1), violations)
          break unless line[j] == '-'
          pos = j
        end
      end

      private def indent_end(line : String) : Int32
        pos = 0
        while pos < line.size && (line[pos] == ' ' || line[pos] == '\t')
          pos += 1
        end
        pos
      end

      private def entry_hyphen?(line : String, pos : Int32) : Bool
        return false if pos >= line.size || line[pos] != '-'
        pos + 1 >= line.size || line[pos + 1] == ' ' || line[pos + 1] == '\t'
      end

      private def content_index(line : String, from : Int32) : Int32?
        j = from
        while j < line.size && (line[j] == ' ' || line[j] == '\t')
          j += 1
        end
        j < line.size ? j : nil
      end

      private def report_gap(file : PositionedFile, line_number : Int32, gap : Int32, violations : Array(Violation)) : Nil
        return if gap <= 1
        violations << Violation.new(file.path, line_number, 0, id, severity,
          "Too many spaces after hyphen")
      end
    end
  end
end
