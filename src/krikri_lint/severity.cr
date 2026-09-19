module Krikri
  module Lint
    enum Severity
      VERY_LOW
      LOW
      MEDIUM
      HIGH
      VERY_HIGH

      def self.parse_lint(value : String) : Severity?
        parse?(value.upcase.gsub("-", "_"))
      end
    end
  end
end
