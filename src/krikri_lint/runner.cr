module Krikri
  module Lint
    class Runner
      @registry : RuleRegistry

      def initialize(@registry)
      end

      def run(paths : Array(String)) : Array(Violation)
        violations = [] of Violation
        paths.each do |path|
          file = PositionedFile.load(path)
          @registry.rules.each do |rule|
            next unless rule.applies?(file)
            rule.check(file, violations)
          end
        end
        violations
      end
    end
  end
end
