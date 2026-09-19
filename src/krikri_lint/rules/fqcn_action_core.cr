module Krikri
  module Lint
    # Upstream parity: ansible-lint's fqcn[action-core] (from the `fqcn`
    # rule, severity MEDIUM, tags formatting). Fires when a task uses a
    # bare name for a module that resolves to an ansible.builtin module.
    class FqcnActionCoreRule < Rule
      def id : String
        "fqcn[action-core]"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Ansible's plugin loader redirects deprecated modules; upstream
      # resolves via resolved_fqcn at runtime.
      REDIRECTS = {
        "yum"                 => "ansible.builtin.dnf",
        "ansible.builtin.yum" => "ansible.builtin.dnf",
      }

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          module_name = task.module_name
          resolved = REDIRECTS[module_name]? ||
                     MODERNIZATION.builtin_alias(module_name) || next
          legacy_module = resolved.sub("ansible.builtin.", "ansible.legacy.")
          next if module_name == resolved || module_name == legacy_module
          violations << Violation.new(
            file.path, task.action_line, task.action_column, id, severity,
            "Use FQCN for builtin module actions (#{module_name}).", task.line
          )
        end
      end
    end
  end
end
