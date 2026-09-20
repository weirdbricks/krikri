module Krikri
  module Lint
    # Upstream parity: ansible-lint's risky-shell-pipe (severity
    # MEDIUM, tags command-shell). shell tasks with a pipe should set
    # pipefail; executable pwsh is exempt.
    class RiskyShellPipeRule < Rule
      def id : String
        "risky-shell-pipe"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["command-shell"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless task.bare_module == "shell"
          next unless truthy_ignore_errors?(task)
          text = raw_command_text(task)
          next unless text
          text = text.gsub(/\{\{.*?\}\}/, "JINJA")
          next unless text.matches?(/(?<!\|)\|(?!\|)/)
          next if text.matches?(/^[ \t]*set.*[+-][A-Za-z]*o[ \t]*pipefail/m)
          next if (executable = task.param("executable")) && executable.includes?("pwsh")
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Shells that use pipes should set the pipefail option.", task.line)
        end
      end

      private def truthy_ignore_errors?(task : LintTask) : Bool
        value = task.task_value("ignore_errors")
        return true if value.nil?
        !%w[false no off 0].includes?(value.downcase)
      end

      private def raw_command_text(task : LintTask) : String?
        if (action = task.action_node).is_a?(YAML::Nodes::Scalar)
          return action.value
        end
        task.param("cmd") || task.param("_raw_params")
      end
    end
  end
end
