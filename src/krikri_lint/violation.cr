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
      # Upstream's MatchError.details: the enclosing task's description,
      # rendered as "Task/Handler: <name>" for matches produced by a
      # task-scoped rule. Empty for file-level rules (yaml[*]).
      getter details : String
      getter? warning : Bool

      def initialize(@path, @line, @column, @rule_id, @severity, @message,
                     @task_line = nil, @warning = false, @details = "")
      end

      def as_warning : Violation
        Violation.new(path, line, column, rule_id, severity, message,
          task_line, true, details)
      end

      def with_details(details : String) : Violation
        Violation.new(path, line, column, rule_id, severity, message,
          task_line, warning?, details)
      end

      # Upstream's MatchError.level.
      def level : String
        warning? ? "warning" : "error"
      end

      # Upstream's MatchError.position: "line", or "line:column" when
      # the rule reported one.
      def position : String
        column > 0 ? "#{line}:#{column}" : line.to_s
      end

      # Rule family: "yaml[commas]" -> "yaml". The summary table and the
      # profile lookups key on the family for bracketed sub-tags.
      def family : String
        rule_id.split("[").first
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
