module Krikri
  module Lint
    # Upstream parity: ansible-lint's risky-octal (severity VERY_HIGH,
    # tags formatting). Flags integer mode values that were meant as
    # octal (e.g. mode: 755) by checking the same sanity conditions
    # upstream's is_invalid_permission uses.
    class RiskyOctalRule < Rule
      MODULES = %w[
        assemble copy file ini_file lineinfile replace synchronize
        template unarchive
      ]

      def id : String
        "risky-octal"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless MODULES.includes?(task.bare_module)
          mode_node = mode_value_node(task) || next
          next unless mode_node.is_a?(YAML::Nodes::Scalar)
          mode = parse_mode(mode_node) || next
          next unless invalid_permission?(mode)
          violations << Violation.new(
            file.path, task.line, NodeUtil.column(task.node), id, severity,
            "`mode: #{mode}` should have a string value with leading zero `mode: \"0#{mode.to_s(8)}\"` or use symbolic mode."
          )
        end
      end

      private def mode_value_node(task : LintTask) : YAML::Nodes::Node?
        action = task.action_node.as?(YAML::Nodes::Mapping) || return nil
        if (entry = NodeUtil.entry(action, "mode"))
          entry[1]
        end
      end

      # Returns the integer mode when the node is a plain (non-quoted)
      # integer; quoted strings are valid upstream and return nil.
      private def parse_mode(node : YAML::Nodes::Scalar) : Int64?
        return nil if node.style != YAML::ScalarStyle::PLAIN
        value = node.value
        return nil unless value && value.matches?(/^\d+$/)
        value.to_i64
      end

      private def invalid_permission?(mode : Int64) : Bool
        user = (mode >> 6) % 8
        group = (mode >> 3) % 8
        other = mode % 8

        other_write_without_read = other != 0 && other < 4 &&
                                   !(other == 1 && (user & 1) == 1)
        group_write_without_read = group != 0 && group < 4 &&
                                   !(group == 1 && (user & 1) == 1)
        user_write_without_read = user != 0 && user < 4 && user != 1

        other_write_without_read || group_write_without_read ||
          user_write_without_read ||
          other > group || other > user || group > user
      end
    end
  end
end
