module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-jinja-when (severity HIGH,
    # tags deprecations). when/changed_when/failed_when are raw Jinja
    # expressions; {{ }} around them is redundant and deprecated.
    class NoJinjaWhenRule < Rule
      WHEN_KEYS = %w[when changed_when failed_when]

      def id : String
        "no-jinja-when"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["autofix", "deprecations"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def fixable? : Bool
        true
      end

      # Upstream's transform strips {{ }} from when/changed_when and
      # failed_when values (RE_JINJA = {{ (.*?) }}), preserving the
      # scalar's quoting. List values are left alone (upstream's
      # transform would crash on them and the match stays unfixed).
      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        target = find_task(file, violation) || return false
        fixed = false
        WHEN_KEYS.each do |key|
          entry = NodeUtil.entry(target.node, key) || next
          value_node = entry[1]
          next unless value_node.is_a?(YAML::Nodes::Scalar)
          value = value_node.value || next
          stripped = value.gsub(/\{\{ (.*?) \}\}/, "\\1")
          next if stripped == value
          line_no = NodeUtil.line(value_node)
          line = buffer.line_text(line_no) || next
          span = FixSpan.scalar_span(line, NodeUtil.column(value_node)) || next
          quote = FixSpan.quote_char(line, NodeUtil.column(value_node))
          replacement = quote ? "#{quote}#{stripped}#{quote}" : stripped
          next unless buffer.replace_span(line_no, span[0] + 1,
                        span[1] - span[0], replacement)
          fixed = true
        end
        fixed
      end

      private def find_task(file : PositionedFile, violation : Violation) : LintTask?
        TaskWalker.each_task(file) do |task|
          return task if task.line == violation.line
        end
        nil
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          # Upstream's matchtask only triggers on `when` (the transform
          # also fixes changed_when/failed_when, but does not report them).
          %w[when].each do |key|
            next unless (entry = NodeUtil.entry(task.node, key))
            value_node = entry[1]
            when_value = NodeUtil.scalar_value(value_node)
            # a single-item list is also checked, like upstream
            if when_value.nil? && (seq = value_node.as?(YAML::Nodes::Sequence)) &&
               seq.nodes.size <= 1
              when_value = seq.nodes.first?.try do |item|
                item.as?(YAML::Nodes::Scalar).try(&.value)
              end
            end
            next unless when_value && when_value.includes?("{{") &&
                        when_value.includes?("}}")
            violations << Violation.new(file.path, task.line, 0, id, severity,
              "No Jinja2 in when", task.line)
            break
          end
        end
      end
    end
  end
end
