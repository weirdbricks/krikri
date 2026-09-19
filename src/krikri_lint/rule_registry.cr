module Krikri
  module Lint
    class RuleRegistry
      getter rules : Array(Rule)

      def initialize(rules : Array(Rule))
        @rules = rules.map &.as(Rule)
      end

      def self.default : RuleRegistry
        new([
          SyntaxCheckRule.new,
          CommandInsteadOfShellRule.new,
          CommandInsteadOfModuleRule.new,
          NoChangedWhenRule.new,
          RiskyFilePermissionsRule.new,
          RiskyOctalRule.new,
          NameRule.new,
          FqcnActionCoreRule.new,
          YamlLineLengthRule.new,
          VarNamingRule.new,
        ])
      end

      def find(id : String) : Rule?
        rules.find(&.id.==(id))
      end
    end
  end
end
