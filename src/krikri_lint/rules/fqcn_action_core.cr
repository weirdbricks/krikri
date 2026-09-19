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

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          module_name = task.module_name
          next if module_name.starts_with?("ansible.builtin.") ||
                  module_name.starts_with?("ansible.legacy.")
          next if MODERNIZATION.builtin_alias(module_name).nil?
          violations << Violation.new(
            file.path, task.line, NodeUtil.column(task.node), id, severity,
            "Use FQCN for builtin module actions (#{module_name})."
          )
        end
      end
    end
  end
end
