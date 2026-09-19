module Krikri
  module Lint
    class Runner
      @registry : RuleRegistry
      @config : LintConfig

      def initialize(@registry, @config = LintConfig.new)
      end

      def run(paths : Array(String)) : Array(Violation)
        rules = active_rules
        return [] of Violation if rules.empty?

        violations = [] of Violation
        noqa_maps = {} of String => Hash(Int32, Noqa::Entry)
        paths.each do |path|
          next if excluded?(path)
          file = PositionedFile.load(path)
          source = File.exists?(path) ? File.read(path) : ""
          noqa_maps[path] = Noqa.build_map(source)
          rules.each do |rule|
            next unless rule.applies?(file)
            rule.check(file, violations)
          end
        end

        result = [] of Violation
        violations.each do |v|
          next if @config.skip_list.includes?(v.rule_id)
          next if Noqa.suppresses?(noqa_maps[v.path]? || {} of Int32 => Noqa::Entry,
                    v.line, v.task_line, v.rule_id)
          v = v.as_warning if @config.warn_list.includes?(v.rule_id)
          result << v
        end
        result
      end

      private def active_rules : Array(Rule)
        @registry.rules.select do |rule|
          next true if @config.enable_list.includes?(rule.id)
          next false unless Profile.includes?(@config.profile, rule.id)
          next true if @config.tags.empty?
          rule.tags.any? { |tag| @config.tags.includes?(tag) } ||
            @config.tags.includes?(rule.id)
        end
      end

      private def excluded?(path : String) : Bool
        @config.exclude_paths.any? do |ex|
          pattern = ex.ends_with?("/") ? ex : ex + "/"
          path.starts_with?(pattern) || path.starts_with?(File.expand_path(pattern))
        end
      end
    end
  end
end
