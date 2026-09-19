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
        ["deprecations"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          WHEN_KEYS.each do |key|
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
