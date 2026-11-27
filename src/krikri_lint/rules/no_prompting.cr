module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-prompting rule (severity
    # VERY_LOW, tags opt-in). A pause with no truthy duration stops an
    # unattended run at a prompt, so upstream reports it at the task's
    # first line with no column.
    class NoPromptingRule < Rule
      MESSAGE = "Disallow prompting."

      # Upstream compares `__ansible_module_original__`, the name as it
      # was written, so these two spellings are the only ones that match:
      # `ansible.legacy.pause` is a different string and goes unreported.
      PAUSE_MODULES = ["pause", "ansible.builtin.pause"]

      # Plain scalars PyYAML resolves to a falsy value. Quoted spellings
      # stay non-empty strings, which upstream's `or` test treats as
      # truthy (so `seconds: "0"` is not a prompt).
      FALSEY_PLAIN = %w[~ null Null NULL false False FALSE no No NO off Off OFF]
      TRUTHY_PLAIN = %w[true True TRUE yes Yes YES on On ON]

      def id : String
        "no-prompting"
      end

      def severity : Severity
        Severity::VERY_LOW
      end

      def tags : Array(String)
        ["opt-in"]
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
        TaskWalker.each_task(file) do |task|
          next unless PAUSE_MODULES.includes?(action_module(task))
          next if param_truthy?(task, "minutes") || param_truthy?(task, "seconds")
          violations << Violation.new(file.path, task.line, 0, id, severity,
            MESSAGE, task.line)
        end
      end

      # An `action:`/`local_action:` directive names its module inside the
      # value, and upstream resolves it before either rule sees the task.
      private def action_module(task : LintTask) : String
        name = task.module_name
        return name unless name == "action" || name == "local_action"
        if free_form = NodeUtil.scalar_value(task.action_node)
          return free_form.split(' ', 2).first? || name
        end
        if mapping = task.action_node.as?(YAML::Nodes::Mapping)
          if (entry = NodeUtil.entry(mapping, "module")) &&
             (value = NodeUtil.scalar_value(entry[1]))
            return value
          end
        end
        name
      end

      # Upstream tests the merged action dict, where a task-level `args:`
      # entry is a default overridden by the action's own parameters.
      # A free-form scalar is parsed by parse_kv, which leaves every value
      # a string, so `pause: minutes=0` is the truthy string "0" while a
      # mapping's plain `minutes: 0` is the integer zero.
      private def param_truthy?(task : LintTask, key : String) : Bool
        node : YAML::Nodes::Node? = nil
        if args = task.args_node.as?(YAML::Nodes::Mapping)
          node = entry_value(args, key)
        end
        if mapping = task.action_node.as?(YAML::Nodes::Mapping)
          if value = entry_value(mapping, key)
            node = value
          end
          return node ? truthy_node?(node) : false
        end
        if scalar = task.action_node.as?(YAML::Nodes::Scalar)
          if value = free_form_value(scalar.value || "", key)
            return !value.empty?
          end
        end
        node ? truthy_node?(node) : false
      end

      private def entry_value(mapping : YAML::Nodes::Mapping, key : String) : YAML::Nodes::Node?
        NodeUtil.entry(mapping, key).try(&.[1])
      end

      private def free_form_value(text : String, key : String) : String?
        text.split(/\s+/).each do |token|
          separator = token.index('=')
          next unless separator
          next unless token[0, separator] == key
          return token[(separator + 1)..]
        end
        nil
      end

      private def truthy_node?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Mapping  then !node.nodes.empty?
        when YAML::Nodes::Sequence then !node.nodes.empty?
        when YAML::Nodes::Scalar   then scalar_truthy?(node)
        else                            true
        end
      end

      private def scalar_truthy?(scalar : YAML::Nodes::Scalar) : Bool
        value = scalar.value || ""
        # Quoted and block scalars are strings: only "" is falsy.
        return !value.empty? unless scalar.style == YAML::ScalarStyle::PLAIN
        plain_scalar_truthy?(value)
      end

      private def plain_scalar_truthy?(value : String) : Bool
        return false if value.empty?
        return false if FALSEY_PLAIN.includes?(value)
        return true if TRUTHY_PLAIN.includes?(value)
        !zero_number?(value)
      end

      # An unquoted number is a Python int/float after parsing, so 0/0.0
      # is falsy; anything that is not a number stays a truthy string.
      private def zero_number?(value : String) : Bool
        number = value.to_f?
        !number.nil? && number == 0.0
      end
    end
  end
end
