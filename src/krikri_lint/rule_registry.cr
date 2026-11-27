module Krikri
  module Lint
    class RuleRegistry
      getter rules : Array(Rule)

      def initialize(rules : Array(Rule))
        @rules = rules.map &.as(Rule)
      end

      def self.default : RuleRegistry
        new([
          LoadFailureRule.new,
          SyntaxCheckRule.new,
          CommandInsteadOfShellRule.new,
          CommandInsteadOfModuleRule.new,
          InlineEnvVarRule.new,
          NoChangedWhenRule.new,
          RiskyFilePermissionsRule.new,
          RiskyOctalRule.new,
          NameRule.new,
          RoleNameRule.new,
          FqcnActionCoreRule.new,
          YamlLineLengthRule.new,
          VarNamingRule.new,
          NoHandlerRule.new,
          NoRelativePathsRule.new,
          NoJinjaWhenRule.new,
          NoTabsRule.new,
          JinjaRule.new,
          SchemaMetaRule.new,
          MetaNoTagsRule.new,
          KeyOrderRule.new,
          LiteralCompareRule.new,
          YamlTrailingSpacesRule.new,
          YamlTruthyRule.new,
          YamlCommentsRule.new,
          YamlEmptyLinesRule.new,
          YamlCommasRule.new,
          YamlColonsRule.new,
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
          PartialBecomeRule.new,
          NoFreeFormRule.new,
          ComplexityRule.new,
          SanityRule.new,
        ])
      end

      def find(id : String) : Rule?
        rules.find(&.id.==(id))
      end
    end
  end
end
