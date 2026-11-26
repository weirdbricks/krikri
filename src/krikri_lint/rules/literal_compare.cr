module Krikri
  module Lint
    # Upstream parity: ansible-lint's literal-compare rule (severity HIGH,
    # tags idiom). A `when:` condition comparing to a literal True/False
    # is redundant: `x == True` is `x`, `x != False` is also `x`, and
    # `x == False` / `x != True` are `not x`. Upstream scans every string
    # when-condition (scalar or list item) with
    # `[=!]= ?(True|true|False|false)` and reports the whole task.
    class LiteralCompareRule < Rule
      LITERAL_COMPARE = /[=!]= ?(?:True|true|False|false)/

      def id : String
        "literal-compare"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["idiom"]
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
          next unless nested_literal_compare?(node)
          line = NodeUtil.line(node)
          violations << Violation.new(file.path, line, 0, id, severity,
            "Don't compare to literal True/False.", line)
        end
      end

      private def nested_literal_compare?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(node) do |key, value|
            if (name = NodeUtil.scalar_value(key)) && name == "when" &&
               literal_compare?(value)
              return true
            end
            return true if nested_literal_compare?(value)
          end
        when YAML::Nodes::Sequence
          node.nodes.each do |item|
            return true if nested_literal_compare?(item)
          end
        end
        false
      end

      private def literal_compare?(node : YAML::Nodes::Node) : Bool
        if value = NodeUtil.scalar_value(node)
          return LITERAL_COMPARE.matches?(value)
        end
        return false unless sequence = node.as?(YAML::Nodes::Sequence)
        sequence.nodes.any? do |item|
          if value = NodeUtil.scalar_value(item)
            LITERAL_COMPARE.matches?(value)
          else
            false
          end
        end
      end
    end
  end
end
