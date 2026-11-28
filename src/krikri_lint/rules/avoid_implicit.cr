module Krikri
  module Lint
    # Upstream parity: ansible-lint's avoid-implicit (severity MEDIUM,
    # tags unpredictability). A copy task's content is only documented as
    # a string, so handing it a mapping or a list makes the module's own
    # templating decide the bytes to write; upstream recommends `template`
    # instead and flags anything but a string.
    class AvoidImplicitRule < Rule
      def id : String
        "avoid-implicit"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["unpredictability"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Upstream's matchtask result belongs to the enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses it.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless copy_module?(task)
          content = content_node(task) || next
          # A Jinja expression is a string here even when the variable it
          # names holds a mapping, so only a value that parses as YAML
          # data is flagged.
          next if NodeUtil.python_str?(content)
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "Avoid implicit behaviors", task.line,
          )
        end
      end

      # ansible-lint strips only the ansible.builtin. prefix before
      # comparing the action name to "copy", so the bare and builtin
      # spellings match while ansible.legacy.copy does not.
      private def copy_module?(task : LintTask) : Bool
        name = task.module_name
        name == "copy" || name == "ansible.builtin.copy"
      end

      # Ansible merges a task's `args:` mapping into the module params, so
      # content can be declared on the module or under args.
      private def content_node(task : LintTask) : YAML::Nodes::Node?
        [task.action_node, task.args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          if (entry = NodeUtil.entry(mapping, "content"))
            return entry[1]
          end
        end
        nil
      end
    end
  end
end
