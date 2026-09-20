module Krikri
  module Lint
    # Upstream parity: yaml[comments] (from yamllint, as configured by
    # ansible-lint's bundled .yamllint: require-starting-space true,
    # min-spaces-from-content 1, ignore-shebangs true). Warning level
    # upstream, so VERY_LOW here. Two messages, both reported at the
    # comment's line with no column:
    # "Missing starting space in comment" and
    # "Too few spaces before comment: expected 1".
    class YamlCommentsRule < Rule
      def id : String
        "yaml[comments]"
      end

      def severity : Severity
        Severity::VERY_LOW
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

      private def scan_line(file : PositionedFile, line : String, line_number : Int32, violations : Array(Violation)) : Nil
        comment_start = find_comment_start(line)
        return if comment_start >= line.size

        check_min_spaces_before(file, line, line_number, comment_start, violations)
        check_starting_space(file, line, line_number, comment_start, violations)
      end

      # Index of the first '#' that starts a comment (line start, after
      # whitespace, or directly after a closed quote), or line.size.
      private def find_comment_start(line : String) : Int32
        in_single = false
        in_double = false
        escaped = false
        quote_closed_at = -1
        i = 0
        while i < line.size
          ch = line[i]
          if in_single
            if ch == '\''
              in_single = false
              quote_closed_at = i
            end
          elsif in_double
            if escaped
              escaped = false
            elsif ch == '\\'
              escaped = true
            elsif ch == '"'
              in_double = false
              quote_closed_at = i
            end
          elsif ch == '\''
            in_single = true
          elsif ch == '"'
            in_double = true
          elsif ch == '#' && comment_boundary?(line, i, quote_closed_at)
            break
          end
          i += 1
        end
        i
      end

      private def comment_boundary?(line : String, i : Int32, quote_closed_at : Int32) : Bool
        i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t' || quote_closed_at == i - 1
      end

      # min-spaces-from-content: only for inline comments (content
      # before the '#' on the same line).
      private def check_min_spaces_before(file : PositionedFile, line : String, line_number : Int32,
                                          comment_start : Int32, violations : Array(Violation)) : Nil
        return unless line[0...comment_start].matches?(/\S/)
        j = comment_start
        while j > 0 && (line[j - 1] == ' ' || line[j - 1] == '\t')
          j -= 1
        end
        return if comment_start - j >= 1
        violations << Violation.new(file.path, line_number, 0, id, severity,
          "Too few spaces before comment: expected 1")
      end

      # require-starting-space: after run(s) of '#', next char must be
      # a space/newline (a '#' at the very end of the line counts as
      # followed by a newline).
      private def check_starting_space(file : PositionedFile, line : String, line_number : Int32,
                                       comment_start : Int32, violations : Array(Violation)) : Nil
        j = comment_start + 1
        while j < line.size && line[j] == '#'
          j += 1
        end
        return if j >= line.size || line[j] == ' ' || line[j] == '\r'
        return if line_number == 1 && comment_start == 0 && line[j] == '!'
        violations << Violation.new(file.path, line_number, 0, id, severity,
          "Missing starting space in comment")
      end
    end
  end
end
