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
          tasks = TaskWalker.collect_tasks(file)
          # Collected once per file, on first need: the enclosing-task
          # spans a task-scoped rule's violations belong to, and the task
          # names those violations are described with.
          if needs_tasks && !task_spans.has_key?(path)
            covered = YamlText.scalar_continuation_lines(file)
            task_spans[path] = tasks.map { |task| {task.line, task.end_line(covered)} }
            task_names[path] = tasks.each_with_object({} of Int32 => String) do |task, map|
              map[task.line] = task.display_name
            end
          end
          next if syntax_check_fails?(file, tasks)
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

      # Upstream's runner runs no rules at all on a file whose
      # `ansible-playbook --syntax-check` fails (ansible-lint
      # runner.py, phase 2): a task module name the controller cannot
      # resolve dies at load with "couldn't resolve module/action", and
      # then only that syntax-check match is reported for the file -
      # every other match is suppressed. Verified against ansible-lint
      # 25.2.1: an unnamed play around `krikri_ok:` reports only
      # syntax-check[unknown-module], while the same play around
      # `ansible.builtin.debug:` reports name[play]. syntax-check is an
      # unimplemented upstream gap here, so such a file produces no
      # violations at all.
      private def syntax_check_fails?(file : PositionedFile, tasks : Array(LintTask)) : Bool
        return false if tasks.empty?
        path = File.expand_path(file.path)
        role_path = role_root(path)
        playbook_dir = File.dirname(path)
        inherited = inherited_collections(file, role_path)
        tasks.any? do |task|
          name = task.module_name
          # Legacy `action:`/`local_action:` directives resolve their
          # module lazily at run time, so an unresolvable one does not
          # fail the load (verified against ansible-lint 25.2.1: `action:
          # unknown x=1` still reports name[play]); the directive key is
          # not a module name and must not be resolved as one.
          next false if name == "action" || name == "local_action"
          collections = own_collections(task) || inherited
          CollectionIndex.controller_resolves?(name, collections, role_path,
            playbook_dir)[:resolves] == false
        end
      end

      # A task's own `collections:` list replaces the inherited scope,
      # the merge real applies (same as the engine's playbook_parser);
      # nil when the task declares none.
      private def own_collections(task : LintTask) : Array(String)?
        entry = NodeUtil.entry(task.node, "collections") || return nil
        string_list(entry[1])
      end

      # The play-level `collections:` lists plus the role's own
      # meta/main.yml declaration, both folded into bare-name resolution
      # by real.
      private def inherited_collections(file : PositionedFile, role_path : String?) : Array(String)
        names = CollectionIndex.role_meta_collections(role_path)
        root = file.root
        if TaskWalker.playbook_root?(file) && (list = root.try(&.as?(YAML::Nodes::Sequence)))
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            entry = NodeUtil.entry(play, "collections") || next
            names += string_list(entry[1])
          end
        end
        names
      end

      # A `collections:` value as real reads it: one name or a list.
      private def string_list(node : YAML::Nodes::Node) : Array(String)
        names = [] of String
        case node
        when YAML::Nodes::Scalar
          names << node.value unless node.value.empty?
        when YAML::Nodes::Sequence
          node.nodes.each do |item|
            if (scalar = item.as?(YAML::Nodes::Scalar)) && !scalar.value.empty?
              names << scalar.value
            end
          end
        end
        names
      end

      # The role a role-tree file belongs to: its own `library/` and
      # `action_plugins/` sources are part of real's name resolution.
      private def role_root(path : String) : String?
        parent = File.basename(File.dirname(path))
        return nil unless %w[tasks handlers vars defaults meta].includes?(parent)
        File.dirname(File.dirname(path))
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
