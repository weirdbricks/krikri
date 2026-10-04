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
        task_spans = {} of String => Array({Int32, Int32})
        task_names = {} of String => Hash(Int32, String)
        needs_tasks = rules.any?(&.task_scoped?)
        paths.each do |path|
          next if excluded?(path)
          file = PositionedFile.load(path)
          source = File.exists?(path) ? File.read(path) : ""
          noqa_maps[path] = Noqa.build_map(source)
          # Collected once per file, on first need: the enclosing-task
          # spans a task-scoped rule's violations belong to, and the task
          # names those violations are described with.
          if needs_tasks && !task_spans.has_key?(path)
            tasks = TaskWalker.collect_tasks(file)
            covered = YamlText.scalar_continuation_lines(file)
            task_spans[path] = tasks.map { |task| {task.line, task.end_line(covered)} }
            task_names[path] = tasks.each_with_object({} of Int32 => String) do |task, map|
              map[task.line] = task.display_name
            end
          end
          rules.each do |rule|
            next unless rule.applies?(file)
            rule.check(file, violations)
          end
        end

        scoped = Set(String).new
        rules.each do |rule|
          next unless rule.task_scoped?
          scoped << rule.id
          scoped << rule.id.split("[").first
        end
        kept = violations.reject { |v| suppressed?(v, scoped, noqa_maps, task_spans) }
        apply_warn_list(kept.map { |v| describe(v, task_names) })
      end

      # Upstream's matchtask attaches the enclosing task's description to
      # every match it produces ("Task/Handler: <name>"), and the default
      # formatter prints it dimmed after the position.
      private def describe(v : Violation, task_names : Hash(String, Hash(Int32, String))) : Violation
        return v unless line = v.task_line
        return v unless name = (task_names[v.path]? || {} of Int32 => String)[line]?
        v.with_details("Task/Handler: #{name}")
      end

      # A violation goes away when the config skips its rule, or when a
      # `# noqa:` covers it. A skip/warn entry may name the rule family
      # ("run-once") or a specific sub-tag ("run-once[task]"); upstream
      # accepts both.
      private def suppressed?(v : Violation, task_scoped : Set(String),
                              noqa_maps : Hash(String, Hash(Int32, Noqa::Entry)),
                              task_spans : Hash(String, Array({Int32, Int32}))) : Bool
        family = v.rule_id.split("[").first
        return true if @config.skip_list.includes?(v.rule_id) ||
                       @config.skip_list.includes?(family)
        map = noqa_maps[v.path]? || {} of Int32 => Noqa::Entry
        # A task-scoped rule's violations belong to an enclosing task, so
        # a `# noqa:` anywhere in that task's body suppresses them. A
        # file-level rule (yaml[*], load-failure) only honours a comment
        # on the violation's own line.
        return Noqa.suppresses?(map, v.line, nil, v.rule_id) unless task_scoped.includes?(family)
        span = enclosing_span(task_spans[v.path]? || [] of {Int32, Int32}, v.line)
        return Noqa.suppresses?(map, v.line, nil, v.rule_id) unless span
        Noqa.suppresses?(map, v.line, span[0], v.rule_id, span[1])
      end

      # Re-applies the warn list after suppression, so a suppressed
      # violation is never demoted on its way out.
      private def apply_warn_list(violations : Array(Violation)) : Array(Violation)
        violations.map do |v|
          family = v.rule_id.split("[").first
          if @config.warn_list.includes?(v.rule_id) || @config.warn_list.includes?(family)
            v.as_warning
          else
            v
          end
        end
      end

      # Innermost task span containing the line.
      private def enclosing_span(spans : Array({Int32, Int32}), line : Int32) : {Int32, Int32}?
        best = nil.as({Int32, Int32}?)
        spans.each do |span|
          next unless line >= span[0] && line <= span[1]
          current = best
          if current.nil? || (span[1] - span[0]) < (current[1] - current[0])
            best = span
          end
        end
        best
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
        @config.excluded?(path)
      end
    end
  end
end
