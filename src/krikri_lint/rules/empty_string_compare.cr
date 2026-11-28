module Krikri
  module Lint
    # Upstream parity: ansible-lint's empty-string-compare (severity HIGH,
    # tags idiom/opt-in). Comparing a value to an empty string is the same
    # as testing the value itself: `x == ""` is `not x`, `x != ""` is `x`.
    # Upstream scans every string when-condition (scalar or list item) for a
    # comparison operator followed by a doubled single or double quote (the
    # space before it optional) and reports the enclosing task.
    class EmptyStringCompareRule < Rule
      EMPTY_STRING_COMPARE = /[=!]= ?("{2}|'{2})/

      def id : String
        "empty-string-compare"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["idiom", "opt-in"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        # Upstream walks each task's whole normalized body
        # (nested_items_path), so a block reports once for every level that
        # encloses a matching when: - the block itself and the child task -
        # and each level's match carries that level's start line.
        TaskWalker.each_task_mapping(file) do |node|
          next unless nested_empty_string_compare?(node)
          line = NodeUtil.line(node)
          violations << Violation.new(file.path, line, 0, id, severity,
            "Don't compare to empty string.", line)
        end
      end

      private def nested_empty_string_compare?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(node) do |key, value|
            if (name = NodeUtil.scalar_value(key)) && name == "when" &&
               empty_string_compare?(value)
              return true
            end
            return true if nested_empty_string_compare?(value)
          end
        when YAML::Nodes::Sequence
          node.nodes.each do |item|
            return true if nested_empty_string_compare?(item)
          end
        end
        false
      end

      private def empty_string_compare?(node : YAML::Nodes::Node) : Bool
        if value = NodeUtil.scalar_value(node)
          return EMPTY_STRING_COMPARE.matches?(value)
        end
        return false unless sequence = node.as?(YAML::Nodes::Sequence)
        sequence.nodes.any? do |item|
          if value = NodeUtil.scalar_value(item)
            EMPTY_STRING_COMPARE.matches?(value)
          else
            false
          end
        end
      end
    end
  end
end
