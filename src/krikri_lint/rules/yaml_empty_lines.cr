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
        ["autofix", "formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def fixable? : Bool
        true
      end

      # The violation points at the last blank line of an over-long
      # run; the run extends upward. Keep the first `max` blank lines
      # of the run and delete the excess.
      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        line_no = violation.line
        max = max_for(buffer, line_no)
        run_start = line_no
        while run_start > 1 && blank?(buffer.line_text(run_start - 1))
          run_start -= 1
        end
        excess_start = run_start + max
        fixed = false
        (excess_start..line_no).each do |line|
          next unless blank?(buffer.line_text(line))
          buffer.delete_line(line)
          fixed = true
        end
        fixed
      end

      private def blank?(text : String?) : Bool
        return false unless text
        text.empty? || text == "\r"
      end

      private def max_for(buffer : FixBuffer, line_no : Int32) : Int32
        run_start = line_no
        while run_start > 1 && blank?(buffer.line_text(run_start - 1))
          run_start -= 1
        end
        return MAX_START if run_start == 1
        rest = ((line_no + 1)..buffer.lines.size).all? do |idx|
          blank?(buffer.line_text(idx))
        end
        rest ? MAX_END : MAX
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
