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
          NoHandlerRule.new,
          NoJinjaWhenRule.new,
          JinjaRule.new,
          SchemaMetaRule.new,
          KeyOrderRule.new,
          YamlTrailingSpacesRule.new,
          YamlTruthyRule.new,
          YamlCommentsRule.new,
          YamlEmptyLinesRule.new,
          YamlHyphensRule.new,
          YamlIndentationRule.new,
          YamlKeyDuplicatesRule.new,
          YamlNewLineAtEndOfFileRule.new,
          YamlOctalValuesRule.new,
          RiskyShellPipeRule.new,
          IgnoreErrorsRule.new,
          RunOnceRule.new,
          LatestRule.new,
          PackageLatestRule.new,
          FqcnCanonicalRule.new,
          ArgsModuleRule.new,
        ])
      end

      def find(id : String) : Rule?
        rules.find(&.id.==(id))
      end
    end
  end
end
