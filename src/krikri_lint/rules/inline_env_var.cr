module Krikri
  module Lint
    # Upstream parity: ansible-lint's inline-env-var (severity VERY_HIGH,
    # tags command-shell/idiom). The command module does not accept
    # `FOO=bar cmd` inline; `shell:` does, so it is exempt. Upstream also
    # fires on a command argument outside its accepted parameter set, so
    # the accepted set is checked as well as the leading word.
    class InlineEnvVarRule < Rule
      EXPECTED_ARGS = %w[
        chdir creates executable removes stdin stdin_add_newline
        strip_empty_ends cmd
      ]

      def id : String
        "inline-env-var"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["command-shell", "idiom"]
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
          # Upstream strips only the ansible.builtin. prefix before this
          # comparison, so ansible.legacy.command stays unflagged there.
          next unless task.module_name.sub("ansible.builtin.", "") == "command"
          # Upstream skips the task entirely when there is no first
          # command word (e.g. an `argv:` list), so the unexpected-argument
          # branch never fires for those either.
          first = first_cmd_arg(task) || next
          next unless first.includes?("=") || unexpected_arg?(task)
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "Command module does not accept setting environment variables inline.",
            task.line,
          )
        end
      end

      # Upstream's get_cmd_args: `cmd:` wins when present, else the
      # free-form arguments. An empty command has no first word. A
      # directive's scalar starts with the module name, which upstream's
      # normalized arguments do not carry.
      private def first_cmd_arg(task : LintTask) : String?
        text = task.param("cmd") || free_form_text(task)
        return nil if text.nil?
        text.split.first?
      end

      private def free_form_text(task : LintTask) : String?
        return task.alias_arguments if task.alias_action?
        NodeUtil.scalar_value(task.action_node)
      end

      private def unexpected_arg?(task : LintTask) : Bool
        [task.action_node, task.args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          NodeUtil.each_entry(mapping) do |key_node, _|
            key = NodeUtil.scalar_value(key_node) || next
            # A directive's `module:` key names the module rather than
            # passing an argument.
            next if task.alias_action? && key == "module"
            return true unless EXPECTED_ARGS.includes?(key)
          end
        end
        false
      end
    end
  end
end
