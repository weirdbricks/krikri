module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-changed-when (severity HIGH,
    # tags command-shell/idempotency). Fires on command/shell/raw tasks
    # with no changed_when, creates, removes, or async poll: 0.
    class NoChangedWhenRule < Rule
      COMMAND_MODULES = %w[command shell raw]

      def id : String
        "no-changed-when"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["command-shell", "idempotency"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless COMMAND_MODULES.includes?(task.bare_module)
          next if task.has_task_key?("changed_when")
          next if task.has_param?("creates") || task.has_param?("removes")
          if task.has_task_key?("async") && task.task_value("poll") == "0"
            next
          end
          violations << Violation.new(
            file.path, task.line, NodeUtil.column(task.node), id, severity,
            "Commands should not change things if nothing needs doing."
          )
        end
      end
    end
  end
end
