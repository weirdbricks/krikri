module Krikri
  module Lint
    # Upstream parity: yaml[empty-lines] (from yamllint defaults, as
    # configured by ansible-lint's bundled .yamllint: max 2, max-start 0,
    # max-end 0; error level, MEDIUM here). Only the last blank line of
    # a run is reported, at that line with no column:
    # "Too many blank lines (N > M)".
    class YamlEmptyLinesRule < Rule
      MAX       = 2
      MAX_START = 0
      MAX_END   = 0

      def id : String
        "yaml[empty-lines]"
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
        return if content.empty? || content == "\n"

        lines = content.split('\n')
        ends_with_newline = content.ends_with?('\n')
        line_count = ends_with_newline ? lines.size - 1 : lines.size

        (1..line_count).each do |line_no|
          next unless blank_line?(lines, line_no, line_count)
          next if blank_line?(lines, line_no + 1, line_count)
          check_run(file, lines, line_no, line_count, ends_with_newline, violations)
        end
      end

      private def blank_line?(lines : Array(String), idx : Int32, line_count : Int32) : Bool
        idx >= 1 && idx <= line_count &&
          (lines[idx - 1].empty? || lines[idx - 1] == "\r")
      end

      private def check_run(file : PositionedFile, lines : Array(String), line_no : Int32,
                            line_count : Int32, ends_with_newline : Bool,
                            violations : Array(Violation)) : Nil
        count = 0
        start = line_no
        while blank_line?(lines, start, line_count)
          count += 1
          start -= 1
        end
        max, count = limits(count, start, line_no, line_count, ends_with_newline)
        return if count <= max
        violations << Violation.new(file.path, line_no, 0, id, severity,
          "Too many blank lines (#{count} > #{max})")
      end

      # Mirrors yamllint: a run reaching the buffer start gets the
      # max-start limit plus one extra line for the missing preceding
      # newline; a run at the end of the file gets max-end.
      private def limits(count : Int32, start : Int32, line_no : Int32,
                         line_count : Int32, ends_with_newline : Bool) : {Int32, Int32}
        if start == 0
          {MAX_START, count + 1}
        elsif line_no == line_count && ends_with_newline
          {MAX_END, count}
        else
          {MAX, count}
        end
      end
    end
  end
end
