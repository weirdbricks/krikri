module Krikri
  module Lint
    # Upstream parity: ansible-lint's deprecated-local-action rule
    # (severity MEDIUM, tags deprecations, autofixable). `local_action`
    # is the old spelling of `delegate_to: localhost`; upstream reports
    # one match per task at the task's first line with no column.
    class DeprecatedLocalActionRule < Rule
      MESSAGE = "Do not use 'local_action', use 'delegate_to: localhost'."

      def id : String
        "deprecated-local-action"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["autofix", "deprecations"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def fixable? : Bool
        true
      end

      # Upstream's transform rewrites the task and marks the match
      # fixed, so no "not applied" is logged.
      def transformable? : Bool
        true
      end

      def marks_fixed?(violation : Violation) : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless local_action_entry(task)
          violations << Violation.new(file.path, task.line, 0, id, severity,
            MESSAGE, task.line)
        end
      end

      # Upstream pops the `local_action` entry, appends the module it
      # named and `delegate_to: localhost` to the task, and drops the
      # mapping form's arguments (verified against
      # `ansible-lint --fix=deprecated-local-action`).
      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        TaskWalker.each_task(file) do |task|
          next unless task.line == violation.line
          entry = local_action_entry(task) || return false
          return rewrite(buffer, file, entry[0], entry[1])
        end
        false
      end

      # The `local_action` entry itself: the task model normalizes the
      # alias to the module it names, so the written key's name is not on
      # the LintTask. `action:` shares that normalization but is a
      # different keyword, so its entry is not this rule's business.
      private def local_action_entry(task : LintTask) : {YAML::Nodes::Node, YAML::Nodes::Node}?
        return nil unless task.alias_action?
        NodeUtil.entry(task.node, "local_action")
      end

      private def rewrite(buffer : FixBuffer, file : PositionedFile,
                          key_node : YAML::Nodes::Node,
                          value_node : YAML::Nodes::Node) : Bool
        line = NodeUtil.line(key_node)
        column = NodeUtil.column(key_node)
        text = buffer.line_text(line) || return false
        # The directive's written span, which runs to the end of its
        # value: the string form's arguments or a flow mapping share the
        # key's line, while the block mapping's arguments are dropped
        # as whole lines below.
        span = FixSpan.scalar_span(text, column) || return false
        replacement = replacement_text(buffer, value_node) || return false
        return false unless buffer.replace_span(line, column,
                              span[1] - (column - 1), replacement)
        dropped_lines(file, key_node, value_node).each do |dropped|
          buffer.delete_line(dropped)
        end
        # Upstream's pop/append walk leaves the rewritten entry where the
        # directive was, so `delegate_to` follows it rather than ending
        # the task; a dropped anchor line would swallow the insertion,
        # hence the directive's own (kept) line.
        buffer.insert_after(line,
          "#{" " * (column - 1)}delegate_to: localhost")
      end

      # The module key upstream writes in place of the directive: the
      # string form keeps its arguments as the module's value, the
      # mapping form's arguments are dropped along with it. The module
      # token is read from the buffer, not the node: an enabled fqcn fix
      # has already renamed it in this same pass, and upstream's
      # transforms run fqcn before this rule, so the key carries the
      # FQCN.
      private def replacement_text(buffer : FixBuffer,
                                   value_node : YAML::Nodes::Node) : String?
        if value_node.is_a?(YAML::Nodes::Scalar)
          text = written_text(buffer, value_node) || return nil
          parts = text.split(' ', 2)
          module_name = parts[0]? || return nil
          return nil if module_name.empty?
          arguments = parts[1]?
          return arguments ? "#{module_name}: #{arguments}" : "#{module_name}:"
        end
        return nil unless mapping = value_node.as?(YAML::Nodes::Mapping)
        entry = NodeUtil.entry(mapping, "module") || return nil
        module_name = written_text(buffer, entry[1]) || return nil
        module_name.empty? ? nil : "#{module_name}:"
      end

      # A scalar's current text, unquoted. Its start position is stable
      # across the fixes in one pass even when the token itself grew
      # (`debug` -> `ansible.builtin.debug`).
      private def written_text(buffer : FixBuffer, node : YAML::Nodes::Node) : String?
        line = buffer.line_text(NodeUtil.line(node)) || return nil
        column = NodeUtil.column(node)
        span = FixSpan.scalar_span(line, column) || return nil
        text = line[(column - 1), span[1] - (column - 1)]
        return text unless text.size >= 2
        quoted = (text.starts_with?('"') && text.ends_with?('"')) ||
                 (text.starts_with?('\'') && text.ends_with?('\''))
        quoted ? text[1, text.size - 2] : text
      end

      # The block-style mapping form's argument lines, which upstream's
      # rewrite discards. A flow mapping sits on the directive's own
      # line and has none.
      private def dropped_lines(file : PositionedFile,
                                key_node : YAML::Nodes::Node,
                                value_node : YAML::Nodes::Node) : Array(Int32)
        mapping = value_node.as?(YAML::Nodes::Mapping) || return [] of Int32
        covered = YamlText.scalar_continuation_lines(file)
        last = NodeUtil.line(key_node)
        NodeUtil.each_entry(mapping) do |key, value|
          last = Math.max(last, NodeUtil.line(key))
          last = Math.max(last, NodeUtil.line(value))
          while covered.includes?(last + 1)
            last += 1
          end
        end
        first = NodeUtil.line(key_node) + 1
        return [] of Int32 if last < first
        (first..last).to_a
      end
    end
  end
end
