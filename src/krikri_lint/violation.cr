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
    end
  end
end
