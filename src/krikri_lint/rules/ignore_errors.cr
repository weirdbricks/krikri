module Krikri
  module Lint
    # Upstream parity: ansible-lint's ignore-errors rule (severity LOW,
    # tags unpredictability). Truthy ignore_errors without register
    # should be failed_when instead.
    class IgnoreErrorsRule < Rule
      def id : String
        "ignore-errors"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["unpredictability"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          value = task.task_value("ignore_errors")
          next unless value && !%w[false no off 0].includes?(value.downcase)
          next if value == "{{ ansible_check_mode }}"
          next if task.has_task_key?("register")
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Use failed_when and specify error conditions instead of using ignore_errors.",
            task.line)
        end
      end
    end
  end
end
