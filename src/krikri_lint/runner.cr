module Krikri
  module Lint
    class Runner
      @registry : RuleRegistry
      @config : LintConfig

      def initialize(@registry, @config = LintConfig.new,
                     @syntax_check : SyntaxCheck? = nil)
      end

      def run(paths : Array(String), targets : Array(String) = paths) : Array(Violation)
        rules = active_rules
        return [] of Violation if rules.empty?

        violations = [] of Violation
        noqa_maps = {} of String => Hash(Int32, Noqa::Entry)
        task_spans = {} of String => Array({Int32, Int32})
        task_names = {} of String => Hash(Int32, String)
        needs_tasks = rules.any?(&.task_scoped?)
        # A file whose playbook syntax check failed gets only the
        # syntax-check match upstream has for it; anything the failed
        # check never loaded is not linted at all (see SyntaxCheck).
        syntax_check = @syntax_check || SyntaxCheck.new(paths, targets)
        paths.each do |path|
          next if excluded?(path)
          next if syntax_check.suppressed?(path)
          file = PositionedFile.load(path)
          if (match = syntax_check.violation(file))
            violations << match
            next
          end
          check_failed = syntax_check.failed?(file)
          source = File.exists?(path) ? File.read(path) : ""
          noqa_maps[path] = Noqa.build_map(source)
          collect_task_metadata(file, task_spans, task_names) if needs_tasks
          rules.each do |rule|
            next unless rule.applies?(file)
            next if check_failed && rule.id != "syntax-check"
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

      # Collected once per file, on first need: the enclosing-task spans a
      # task-scoped rule's violations belong to, and the task names those
      # violations are described with.
      private def collect_task_metadata(file : PositionedFile,
                                        task_spans : Hash(String, Array({Int32, Int32})),
                                        task_names : Hash(String, Hash(Int32, String))) : Nil
        return if task_spans.has_key?(file.path)
        tasks = TaskWalker.collect_tasks(file)
        covered = YamlText.scalar_continuation_lines(file)
        task_spans[file.path] = tasks.map { |task| {task.line, task.end_line(covered)} }
        task_names[file.path] = collect_task_names(file, tasks)
      end

      # The "Task/Handler: <name>" description of every task in a file. A
      # block parent is a task to Ansible, so it is described too (an
      # unnamed one as its dummy "block/always/rescue" action), but it
      # stays out of the task spans: a `# noqa:` buried in a child task
      # must not suppress a match on the block itself.
      private def collect_task_names(file : PositionedFile,
                                     tasks : Array(LintTask)) : Hash(Int32, String)
        names = tasks.each_with_object({} of Int32 => String) do |task, map|
          map[task.line] = task.display_name
        end
        TaskWalker.each_block(file) do |block|
          block_entry = NodeUtil.entry(block, "block") || next
          lint_task = LintTask.new(block, file, "block/always/rescue",
            block_entry[1], block_entry[0])
          names[lint_task.line] ||= lint_task.display_name
        end
        names
      end

      # Upstream's matchtask enrichment (_enrich_matcherror_with_task_details)
      # attaches the enclosing task's description ("Task/Handler: <name>")
      # to every match it produces, but only when the match carries no
      # details of its own - a rule that reported one (fqcn[action-core],
      # jinja[spacing]) keeps it, and the default formatter prints it
      # dimmed after the position instead.
      private def describe(v : Violation, task_names : Hash(String, Hash(Int32, String))) : Violation
        return v unless v.details.empty?
        return v unless line = v.task_line
        return v unless name = (task_names[v.path]? || {} of Int32 => String)[line]?
        v.with_details("Task/Handler: #{name}")
      end

      # A violation goes away when the config skips its rule, or when a
      # `# noqa:` covers it. A skip/warn entry may name the rule family
      # ("run-once") or a specific sub-tag ("run-once[task]"); upstream
      # accepts both, and also matches either list against the rule's
      # declared category tags (a warn entry of "experimental" demotes
      # every rule tagged experimental, not just ones named exactly).
      private def suppressed?(v : Violation, task_scoped : Set(String),
                              noqa_maps : Hash(String, Hash(Int32, Noqa::Entry)),
                              task_spans : Hash(String, Array({Int32, Int32}))) : Bool
        family = v.rule_id.split("[").first
        return true if list_matches?(@config.skip_list, v)
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
          if list_matches?(@config.warn_list, v)
            v.as_warning
          else
            v
          end
        end
      end

      # Upstream's membership test for skip/warn entries: a match is
      # covered when its full tag ("jinja[spacing]"), its rule id
      # ("jinja"), or any of the rule's category tags is listed.
      private def list_matches?(entries : Array(String), v : Violation) : Bool
        family = v.family
        return true if entries.includes?(v.rule_id) || entries.includes?(family)
        rule = @registry.rules.find { |reg_rule| reg_rule.id == family }
        return false unless rule
        rule.tags.any? { |tag| entries.includes?(tag) }
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
