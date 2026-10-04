module Krikri
  module Lint
    # Upstream parity: no-free-form (severity MEDIUM, tags syntax/risk).
    # Flags `module: "some string with k=v"` - the free-form calling
    # convention, where module arguments are crammed into a single
    # string instead of passed as a mapping. It hides typos (a misspelled
    # key is silently dropped by the module) and defeats argument
    # validation, so upstream steers users to the explicit form.
    #
    # Two exemptions upstream makes:
    #  - include/import actions, whose string *is* the argument list
    #  - command/shell free-form that carries no `key=` option, i.e. a
    #    plain command line with nothing to unpack
    class NoFreeFormRule < Rule
      INCLUSION_ACTIONS = %w[
        include include_tasks import_playbook import_tasks
        ansible.builtin.include ansible.builtin.include_tasks
        ansible.builtin.import_playbook ansible.builtin.import_tasks
      ]

      # Modules whose free form is a command line, where only a `key=`
      # option makes it a free-form call worth flagging.
      CMD_SHELL_MODULES = %w[
        ansible.builtin.command ansible.builtin.shell
        ansible.windows.win_command ansible.windows.win_shell
        command shell win_command win_shell
      ]

      # Option names that mark a command/shell free form as carrying
      # module arguments rather than just a command line.
      CMD_SHELL_OPTION = /(chdir|creates|executable|removes|stdin|stdin_add_newline|warn)=/

      def id : String
        "no-free-form"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["syntax", "risk"]
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
          next if INCLUSION_ACTIONS.includes?(task.module_name)
          next unless (value = task.action_node).is_a?(YAML::Nodes::Scalar)
          raw = value.value
          next unless raw && raw.includes?("=")
          next unless flagged?(task.bare_module, raw)
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Avoid using free-form when calling module actions. " \
            "(#{task.module_name})", task.line)
        end
      end

      private def flagged?(module_name : String, raw : String) : Bool
        return raw.matches?(CMD_SHELL_OPTION) if CMD_SHELL_MODULES.includes?(module_name)
        true
      end
    end
  end
end
