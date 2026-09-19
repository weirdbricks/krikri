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

      def initialize(@path, @line, @column, @rule_id, @severity, @message)
      end

      def self.toJson(violations : Array(Violation)) : String
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
