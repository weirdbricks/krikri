require "json"

module Krikri
  module Lint
    struct Violation
      getter path : String
      getter line : Int32
      getter column : Int32
      getter rule_id : String
      getter severity : Severity
      getter message : String
      # Enclosing task's first line, for noqa range matching. Nil for
      # file-level rules (yaml[*], syntax-check).
      getter task_line : Int32?
      getter? warning : Bool

      def initialize(@path, @line, @column, @rule_id, @severity, @message,
                     @task_line = nil, @warning = false)
      end

      def as_warning : Violation
        Violation.new(path, line, column, rule_id, severity, message,
          task_line, true)
      end

      def self.to_json(violations : Array(Violation)) : String
        JSON.build do |json|
          json.array do
            violations.each do |v|
              json.object do
                json.field "path", v.path
                json.field "line", v.line
                json.field "column", v.column
                json.field "rule_id", v.rule_id
                json.field "severity", v.severity.to_s.downcase
                json.field "message", v.message
              end
            end
          end
        end
      end
    end
  end
end
