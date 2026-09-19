module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-handler (severity MEDIUM,
    # tags idiom). Tasks with a simple when referencing .changed /
    # |changed / ["changed"] / is changed are acting as handlers.
    class NoHandlerRule < Rule
      CHANGED_MARKERS = [".changed", "|changed", "| changed", "[\"changed\"]",
                         "['changed']", "is changed"]

      def id : String
        "no-handler"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return if file.file_type.handlers?
        TaskWalker.each_task(file) do |task|
          next if task.handlers_section?
          next if task.has_task_key?("listen")
          when_value = task.task_value("when")
          next unless when_value && changed_in_when?(when_value)
          name_value = task.name_node
          line = name_value ? NodeUtil.line(name_value) : task.line
          column = name_value ? NodeUtil.column(name_value) : 0
          violations << Violation.new(file.path, line, column, id, severity,
            "Tasks that run when changed should likely be handlers.", task.line)
        end
      end

      private def changed_in_when?(value : String) : Bool
        return false if value.split(/\s+/).any? { |t| {"and", "or", "not"}.includes?(t) }
        CHANGED_MARKERS.any? { |marker| value.includes?(marker) }
      end
    end
  end
end
