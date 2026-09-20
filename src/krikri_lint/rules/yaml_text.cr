module Krikri
  module Lint
    # Shared helpers for the line-oriented yaml[*] rules (comments,
    # hyphens): they scan raw text, so lines that are continuation
    # content of multi-line scalars (block scalars, quoted scalars
    # spanning lines) must be excluded - inside them, "#" and "-" are
    # scalar text, not comments/indicators.
    module YamlText
      extend self

      # Lines (1-based) that are continuation content of a multi-line
      # scalar. Block scalars report their content via the scalar value
      # itself (the node's end mark points at the next token, not the
      # content end); quoted scalars end at their closing quote.
      def scalar_continuation_lines(file : PositionedFile) : Set(Int32)
        covered = Set(Int32).new
        root = file.root || return covered
        NodeUtil.walk(root) do |node|
          next unless scalar = node.as?(YAML::Nodes::Scalar)
          next if scalar.start_line == scalar.end_line
          case scalar.style
          when YAML::ScalarStyle::LITERAL, YAML::ScalarStyle::FOLDED
            value = scalar.value || ""
            content_lines = value.split('\n').size - (value.ends_with?('\n') ? 1 : 0)
            last = scalar.start_line + content_lines
          else
            last = scalar.end_line
          end
          ((scalar.start_line + 1)..last).each { |line_no| covered << line_no }
        end
        covered
      end

      # Split file content into physical lines (without line terminators).
      # A trailing empty element for a file ending in "\n" is dropped, so
      # index 0 is line 1 and lines.size is the real line count.
      def physical_lines(path : String) : Array(String)
        content = File.exists?(path) ? File.read(path) : ""
        lines = content.split('\n')
        lines.pop if !lines.empty? && lines.last.empty? && content.ends_with?('\n')
        lines
      end
    end
  end
end
