require "./executor"

module Krikri
  class TaskExecutor
    private def execute_block_multi(task : Task, hosts : Array(Host)) : Nil
      run_hosts, skip_hosts = partition_by_when(task, hosts, inherit_on_error: true)

      skip_hosts.each do |host|
        # A block's when: is inherited by every task inside block: and
        # always: (verified against real ansible-playbook) - rescue: is
        # left alone since it only ever runs if the block itself
        # actually failed, which can't happen when it never ran at all.
        print_skipped_tasks(task.block_tasks || [] of Task, host)
        print_skipped_tasks(task.always_tasks || [] of Task, host)
      end
      return if run_hosts.empty?

      failed_before = Hash(String, Int32).new
      run_hosts.each { |host| failed_before[host.name] = @results[host.name]["failed"] }
      # Same block-level notify: tracking as execute_block's own
      # changed_before - see that method's comment.
      changed_before = Hash(String, Int32).new
      run_hosts.each { |host| changed_before[host.name] = @results[host.name]["changed"] }

      propagate_role_context(task, task.block_tasks || [] of Task)
      run_task_batch(task.block_tasks || [] of Task, run_hosts)

      block_failed = Hash(String, Bool).new
      run_hosts.each { |host| block_failed[host.name] = @halted_hosts.includes?(host.name) }

      if (rescue_tasks = task.rescue_tasks) && block_failed.any? { |_, failed| failed }
        rescue_hosts = run_hosts.select { |host| block_failed[host.name] }
        rescue_hosts.each { |host| @halted_hosts.delete(host.name) }

        # Same as execute_block's single-host path: the block-body
        # failure moves into "rescued" as soon as rescue: is ENTERED,
        # not only when the rescue then succeeds (live-verified against
        # ansible-core 2.19.12, round173 - failing block + failing
        # rescue recaps as `failed=1 rescued=1`).
        rescue_hosts.each do |host|
          recovered = @results[host.name]["failed"] - failed_before[host.name]
          if recovered > 0
            @results[host.name]["failed"] -= recovered
            @results[host.name]["rescued"] += recovered
          end
        end

        propagate_role_context(task, rescue_tasks)
        run_task_batch(rescue_tasks, rescue_hosts)

        rescue_hosts.each do |host|
          block_failed[host.name] = @halted_hosts.includes?(host.name)
        end
      end

      if always_tasks = task.always_tasks
        run_hosts.each { |host| @halted_hosts.delete(host.name) }
        propagate_role_context(task, always_tasks)
        run_task_batch(always_tasks, run_hosts)
        run_hosts.each { |host| block_failed[host.name] ||= @halted_hosts.includes?(host.name) }
      end

      notify_hosts_if_changed(task, run_hosts, changed_before)

      run_hosts.each do |host|
        @halted_hosts.delete(host.name)
        halt_if_failed(task, host, block_failed[host.name])
      end
    end

    private def execute_include_tasks_multi(task : Task, hosts : Array(Host)) : Nil
      puts "TASK [#{task_role_prefix(task)}#{render_task_name_for_display(task, hosts.first)}]".colorize(:white).bold
      puts "*" * 70

      run_hosts, skip_hosts = partition_by_when(task, hosts)

      skip_hosts.each do |host|
        puts "skipping: [#{host.connection_host}]".colorize(:cyan)
        @results[host.name]["skipped"] += 1
      end

      run_groups = Hash(String, Array(Host)).new { |hash, key| hash[key] = [] of Host }
      run_hosts.each do |host|
        begin
          vars_context = build_vars_context(task, host)
        rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
          # Same degrade-to-one-clean-failed-task shape as execute_task's
          # own build_vars_context rescue (0.9.885): the include_tasks:
          # statement's own `vars:` block used an unknown filter (e.g. a
          # role-local filter like stackhpc.luks's luks_key), real Ansible
          # fails just that include task with "No filter named 'X'." -
          # nothing here caught it, so the whole process crashed out of
          # run_task_batch instead. Only THIS host fails; the rest of
          # run_hosts still proceed (same per-host swallow partition_by_
          # when's own WhenEvaluationError rescue below uses).
          swallow_when_error(task, host, WhenEvaluationError.new(ex.message || "Failed to render task vars"))
          next
        end
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        file_rel = substitutor.substitute(task.include_file.as(String))
        resolved_path = PlaybookParser.resolve_include_path(file_rel, task.include_file_dir.as(String))

        unless File.exists?(resolved_path)
          fail_include(task, host, "Included tasks file not found: #{resolved_path}")
          next
        end

        # The include_tasks: task itself counts as one `ok` in the
        # recap, matching real Ansible and the single-host
        # execute_include_tasks path above - this multi-host batched
        # path never credited it at all, undercounting the recap's
        # `ok=` tally by one per host for every non-looped include_
        # tasks: task. Found benchmarking robertdebock.openvpn's own
        # "Setup openvpn server or client".
        @results[host.name]["ok"] += 1
        run_groups[resolved_path] << host
      end

      puts ""

      run_groups.each do |resolved_path, group_hosts|
        begin
          yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
          # A comment-only (or entirely blank) tasks file - real Ansible
          # treats this as zero tasks, not an error (ansistrano.deploy's
          # own tasks/empty.yml, deliberately shipped as a no-op include
          # target for every before_*/after_* hook point a caller
          # doesn't override - see #resolve_include_path's own comment
          # for the sibling fix found in the same round). YAML.parse
          # returns a bare `nil` document for comment-only content, NOT
          # an empty array, so this can't just be folded into the
          # `unless yaml.as_a?` check below without also accepting a
          # genuinely malformed (e.g. a bare scalar/mapping) tasks file.
          if yaml.raw.nil?
            next
          end
          unless yaml.as_a?
            group_hosts.each { |host| fail_include(task, host, "Included tasks file must be a YAML list: #{resolved_path}") }
            next
          end

          inherited = Play.new("", "")
          inherited.become = task.become?
          inherited.become_user = task.become_user
          included_tasks = PlaybookParser.parse_tasks(yaml.as_a, inherited, "task in included #{resolved_path}", File.dirname(resolved_path), role_path: task.role_path, playbook_dir: @playbook_dir)

          if include_vars = task.include_vars
            included_tasks.each do |included_task|
              include_vars.each { |key, value| included_task.vars[key] = value }
            end
          end

          # The included tasks' own `name:` strings are NOT pre-substituted
          # here - same rationale as run_include_tasks_once's matching note
          # below: an eager pass baked names once per file against a
          # representative host's include-entry context, which permanently
          # froze any name referencing a fact the included file's own
          # earlier tasks set (or a per-host value) to that one moment.
          # Banners render lazily at print time instead, per host.

          propagate_role_context(task, included_tasks)

          connection_names = group_hosts.map { |host| host.vars["ansible_host"]?.try(&.as_s?) || host.name }
          puts "included: #{resolved_path} for #{connection_names.join(", ")}".colorize(:cyan)
          puts ""

          run_task_batch(included_tasks, group_hosts)
        rescue ex : HandlerNotFoundError
          # A notify: naming a nonexistent handler aborts the whole run
          # (real Ansible's own behavior) - it must not be swallowed
          # into a per-task "Failed to load included tasks" failure just
          # because the notifying task came from an included file. This
          # is the one path that made the pre-0.9.600 parse-time check
          # miss the case entirely.
          raise ex
        rescue ex : UnresolvedModuleError
          # Same bypass, same reason: an included file's task naming a
          # module real Ansible can't resolve anywhere aborts the whole
          # run (real Ansible's playbook-load check), it must not
          # degrade to a per-task "Failed to load included tasks"
          # failure. See UnresolvedModuleError's own comment.
          raise ex
        rescue ex
          group_hosts.each { |host| fail_include(task, host, "Failed to load included tasks: #{ex.message}") }
        end
      end
    end

    # Runs *task* against every host in *hosts* concurrently instead of
    # one at a time, via a bounded pool of fibers (same Channel-gated
    # shape as gather_facts_for_all_hosts's Stage A parallelism) capped at
    # @forks. Safe with no locks: only one fiber runs Crystal code at any
    # instant (cooperative scheduling), and every per-host mutation this
    # touches (@results[host.name], @registered_vars[host.name],
    # @facts[host.name], @batch_cache[host.name], @halted_hosts.add) is
    # either a disjoint pre-seeded hash key or a Set#add with no yield
    # point mid-operation - never actually racing.
    #
    # Shared-Task field writes are safe too, audited for exactly that:
    # the per-host-looking ones (execute_include_role's/item binding,
    # run_include_tasks_once's name substitution and vars: injection)
    # all hit Task objects parsed FRESH inside that same per-host call,
    # and the writes onto SHARED block children (inherit_when_condition,
    # propagate_role_context, execute_include_tasks_multi's include_vars
    # injection) assign host-INDEPENDENT values idempotently (their own
    # guards converge on one final value no matter how hosts interleave)
    # with no yield point mid-write - and every one of those sites runs
    # before this dispatch anyway. render_task_vars deliberately renders
    # into the per-call vars_context copy, never back into task.vars,
    # so no host's templated values can ever bake into a shared Task.
    #
    # The one real hazard is stdout: each host's fiber redirects its own
    # output to a private buffer via OutputRouting (so concurrent hosts'
    # lines never interleave), then every buffer is flushed in *hosts*
    # order only after every fiber has finished - output stays stable
    # regardless of which host's SSH round trip actually finished first.
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: dispatch via the
    # `@host_worker_pool`'s persistent per-host fibers (one spawn per
    # host for the executor's lifetime) instead of spawning a fresh
    # fiber per (task, host) pair. The per-call gate is preserved so
    # `@forks` still bounds concurrency - the gate lives INSIDE the
    # worker loop now, so workers serialize on it the same way the old
    # per-call spawn pattern did, but the worker fiber itself survives
    # across tasks.
    private def task_role_prefix(task : Task) : String
      role_name = task.role_name
      return "" unless role_name
      return "" if task.module_name == "_include_role"
      "#{role_name} : "
    end

    # Substitutes each *notify_list* entry against *task*'s own
    # vars_context before handing it to HandlerRunner - `task.notify` is
    # set once at parse time from raw YAML strings and was never
    # substituted anywhere before this, so a templated notify: (the
    # `prometheus.prometheus` collection's own internal `_common` role
    # idiom: `notify: "{{ ansible_parent_role_names | first }} : Restart
    # {{ _common_service_name }}"`) never matched the handler it was
    # meant to trigger at all - the handler simply never ran. Lazy, same
    # pattern as #render_task_name_for_display: only builds a
    # vars_context (not otherwise available at every one of this
    # method's three call sites, which don't all already have one in
    # scope) when at least one entry actually needs it. Found live
    # investigating round 28's prometheus.prometheus.pushgateway.
    private def render_include_role_vars(vars : Hash(String, JSON::Any)?, vars_context : Hash(String, JSON::Any), host_name : String) : Hash(String, JSON::Any)
      return Hash(String, JSON::Any).new unless vars

      # The fix above (rendering each entry via
      # render_include_role_var_value) still only worked when a vars:
      # entry referenced something ALREADY in vars_context - a sibling
      # entry from the SAME vars: block wasn't visible yet, because
      # each was rendered one at a time straight against the original
      # (unmodified) vars_context. A Hash has no meaningful evaluation
      # order to Jinja - real Ansible's per-key lazy templating lets a
      # vars: entry reference another regardless of which is written
      # first in the YAML - but this did: linux-system-roles.logging's
      # own `vars:` declares `rsyslog_custom_config_files: "{{
      # __custom_config_files + logging_custom_config_files }}"`
      # BEFORE the `__custom_config_files:` entry it depends on, so
      # `__custom_config_files` looked up as whatever vars_context
      # already had for that name (nothing) instead of this same
      # include_role's own sibling definition - `rsyslog_custom_config_files`
      # ended up "{{ }}" (undefined) concatenated with logging_custom_
      # config_files, silently mis-rendering to the empty list's own
      # STRING representation "[]" rather than a real empty array
      # (surfaced when `| flatten` then split that 2-character string
      # into two bogus loop items "[" and "]", each fed to `copy: src:`
      # as a nonexistent file path). Mirrors build_vars_context +
      # render_task_vars's own pattern for a regular task's vars: -
      # seed every sibling's raw value into a scratch context FIRST,
      # then render each key against that (so a forward reference sees
      # the other's raw text and recursively re-renders it, the same
      # way render_task_vars's substitutor lookups already do).
      scratch = vars_context.dup
      vars.each { |key, value| scratch[key] = value }

      rendered_vars = Hash(String, JSON::Any).new
      vars.each_key do |key|
        rendered_vars[key] = render_include_role_var_value(scratch[key], scratch, host_name)
      end
      rendered_vars
    end

    # Recurses into a vars: value so a list-of-dicts (e.g. `service_
    # list:` on robertdebock.node_red's `import_role: name: robertdebock.
    # service`, each entry with its own `{{ node_red_service }}`-style
    # fields) gets every nested String leaf rendered, not just a
    # top-level scalar. Previously only checked `value.raw.as?(String)`
    # directly, so any Array/Hash-shaped var passed through completely
    # unrendered - every `{{ }}` inside it landed on the included role
    # literally, showing up downstream as the string "undefined" once
    # VariableLookup gave up resolving it.
    private def render_include_role_var_value(value : JSON::Any, vars_context : Hash(String, JSON::Any), host_name : String) : JSON::Any
      case raw = value.raw
      when String
        return value unless raw.includes?("{{")
        if native = evaluate_bare_mustache_preserving_type(raw, vars_context)
          return native
        end
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        rendered = substitutor.substitute(raw)
        parsed = (rendered.starts_with?('{') || rendered.starts_with?('[')) ? (JSON.parse(rendered) rescue nil) : nil
        parsed || JSON::Any.new(rendered)
      when Array
        JSON::Any.new(raw.map { |item| render_include_role_var_value(item, vars_context, host_name) })
      when Hash
        rendered_hash = Hash(String, JSON::Any).new
        raw.each { |k, v| rendered_hash[k] = render_include_role_var_value(v, vars_context, host_name) }
        JSON::Any.new(rendered_hash)
      else
        value
      end
    end

    private def resolve_include_vars_path(task : Task, candidate : String) : String?
      return File.exists?(candidate) ? candidate : nil if candidate.starts_with?("/")

      roots = [] of String
      if vars_dir = task.role_vars_dir
        roots << vars_dir
        roots << File.join(File.dirname(vars_dir), "defaults")
      end
      task.include_file_dir.try { |dir| roots << dir }
      # A relative include_vars: path in a role's own top-level tasks/
      # main.yml (not reached via include_tasks:, so include_file_dir
      # above is nil) resolves against that file's own directory, real
      # Ansible's usual "relative to the file it's written in" rule -
      # jnv.debian-backports's own `include_vars: "../defaults/{{
      # ansible_distribution }}.yml"` needs roles/<role>/tasks/ as a
      # root to reach roles/<role>/defaults/Ubuntu.yml via the literal
      # "../defaults/" it wrote. Without this, a role with no vars/ dir
      # at all (only defaults/, like this one) had no matching root
      # here whatsoever - role_vars_dir stays nil, include_file_dir
      # stays nil, leaving only the process's own irrelevant Dir.current.
      task.role_path.try { |role_dir| roots << File.join(role_dir, "tasks") }
      roots << Dir.current

      first_existing(roots, candidate)
    end

    private def execute_include_vars(task : Task, host : Host) : Nil
      begin
        vars_context = build_vars_context(task, host)
      rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
        # Same degrade-to-one-clean-failed-task shape as the include_
        # tasks/include_role paths' own build_vars_context rescues: the
        # include_vars: statement's own `vars:` block used an unknown
        # filter, real Ansible fails just that task with "No filter
        # named 'X'." - via this file's own include_vars failure shape
        # (stats/halt/print, respecting ignore_errors:).
        finish_include_vars_failure(task, host, ex.message || "Failed to render task vars")
        return
      end

      # The dir: form (load every vars file in a directory) runs through
      # its own path below - before the loop machinery, which keys off
      # include_vars_file and would have nothing to substitute for a
      # dir:-mode task.
      if task.include_vars_dir
        execute_include_vars_dir(task, host, vars_context)
        return
      end

      # A real `loop:` (as opposed to with_first_found, handled below)
      # was previously ignored entirely here - include_vars: was
      # dispatched to this method before the generic loop-handling in
      # #execute_task ever ran (see the `return
      # execute_include_vars(task, host) if task.include_vars?` early
      # return there), so the task ran once with no `item` bound at
      # all. Any `vars:`/`when:` referencing `{{ item }}` (the
      # linux-system-roles.* "Set platform/version specific
      # variables" pattern: `include_vars: "{{ role_path }}/vars/{{
      # item }}"` looped over os_family/distribution/distribution_
      # major_version/distribution_version candidate filenames, each
      # gated by `when: __vars_file is file`) silently resolved `item`
      # as undefined and skipped every candidate - found live
      # benchmarking linux-system-roles.storage (round 159).
      # A TEMPLATED loop: (`loop: "{{ query('first_found', params) }}"` -
      # buluma.confluence's own style, the modern idiom real ansible
      # roles increasingly use in place of the with_first_found: keyword
      # below) isn't a literal YAML list, so task.loop_items is nil for
      # it - resolve_loop_template (the SAME general-purpose resolver
      # #execute_task's own loop handling uses) is the fallback. Without
      # this, a templated loop: fell all the way through to the single-
      # invocation path below with NO item ever bound, so `include_vars:
      # "{{ _loop_var }}"` (whatever the role names its loop_control:
      # loop_var:) always resolved to this engine's own "undefined"
      # sentinel regardless of what the template actually evaluated to.
      # Found live benchmarking buluma.confluence (round 165).
      #
      # resolve_loop_items_or_raise: round174 matrix scenario 12c - a
      # genuinely undefined loop: source must fail this include_vars:
      # task itself ("'the_var' is undefined"), not silently try to load
      # a file literally named "undefined" (the old bug: the engine's
      # own "undefined" sentinel string leaking through as a filename).
      begin
        loop_items = resolve_loop_items_or_raise(task, host, vars_context) do
          task.loop_items || resolve_loop_template(task, vars_context) || resolve_loop_nested(task, vars_context, host.name) || resolve_fileglob(task, host, vars_context)
        end
      rescue ex : WhenEvaluationError
        finish_include_vars_failure(task, host, ex.message || "is undefined")
        return
      end

      if loop_items
        executed = false
        failed = false
        # `register:` on a looped include_vars: (pacifica.ansible_pacifica's
        # own `register: vars_result` + `loop: "{{
        # pacifica_enabled_services }}"`, then `vars_result.results |
        # items2dict(key_name='item', value_name='ansible_facts')`) was
        # never populated at all - this whole loop body had no register
        # handling, so `vars_result` stayed entirely unset and any later
        # reference raised "'vars_result.results' is undefined". Each
        # entry mirrors real Ansible's own include_vars module result
        # shape (`ansible_facts:` holding the loaded vars, `changed:
        # false` - include_vars never mutates remote state) plus `item:`,
        # matching the generic looped-task register shape in
        # executor_loops.cr. Scoped to the success/file-not-found/parse-
        # error paths below (the three a real playbook's register:
        # + items2dict/selectattr idiom actually reads); a when:-skipped
        # item isn't appended, a narrower gap than the fully generic
        # looped-module path.
        item_results = [] of JSON::Any
        rendered_items = loop_items.map { |item| deep_render_item(item, vars_context, host.name, strict: false) }
        rendered_items = flatten_with_items_one_level(rendered_items) if task.loop_items_needs_flatten?
        rendered_items.each_with_index do |item, loop_index|
          item_context = vars_context.dup
          item_context["item"] = item
          item_context["ansible_loop"] = ansible_loop_vars(rendered_items, loop_index) if task.loop_extended?
          # loop_control: { loop_var: some_name } exposes the item under
          # a CUSTOM name instead of (real Ansible: in addition to) the
          # default "item" - previously ignored entirely here, always
          # binding only "item" regardless. buluma.confluence's own
          # `loop_control: { loop_var: _loop_var }` needs `_loop_var`
          # bound for its own `include_vars: "{{ _loop_var }}"` to
          # resolve at all (round165).
          if lv = task.loop_var
            item_context[lv] = item
          end
          # task.vars (e.g. `__vars_file: "{{ role_path }}/vars/{{ item
          # }}"`) is stored unrendered in vars_context - it must be
          # re-rendered against THIS item before when: (which reads it
          # as a bare variable, not a "{{ }}" expression) can see the
          # real path, matching execute_looped_task's own identical
          # per-iteration re-render.
          task.vars.each { |key, raw_value| item_context[key] = raw_value unless key == "item" }
          render_task_vars(task, item_context, host.name)
          # item_display (Ansible's own compact JSON-ish display, e.g.
          # {"changed":false,"item":"ungrouped",...}), not raw
          # JSON::Any#to_s - found via ipr-cnrs.nftables's own looped
          # include_vars: task, whose "skipping: ... => (item=...)"
          # line leaked Crystal's own JSON::Any(...)-wrapped inspect
          # text (`{"changed" => JSON::Any(false), ...}`) instead of a
          # clean value, unlike every other looped-task display in this
          # codebase (which already goes through this same helper).
          item_label = item_display(item)
          begin
            next unless when_passes?(task, item_context, host, item_label: item_label, defer_stats: true)
          rescue ex : WhenEvaluationError
            puts "failed: [#{host.connection_host}] => (item=#{item_label})".colorize(:red)
            puts "  Message: #{ex.message}".colorize(:red)
            failed = true
            next
          end

          substitutor = VarSubstitutor.new(vars: item_context, host_name: host.name)
          candidate = begin
            substitutor.scan_strict_include_vars_path(task.include_vars_file || "", task.vars)
            substitutor.substitute(task.include_vars_file || "", strict: true).strip
          rescue ex : UndefinedVariableError | FirstFoundLookupError
            # Real Ansible templates include_vars's own path strictly
            # (verified live against 2.19.4: `include_vars: "{{ users }}"`
            # with no `users` anywhere fails THIS task - "Error while
            # resolving value for '_raw_params': 'users' is undefined",
            # rc=2) - it never renders the path to a literal "undefined"
            # and then reports "file not found: undefined". Same cause-text
            # convention as every other module's undefined-arg failure
            # (see prepare_batch_step's own finalization rescue).
            puts "failed: [#{host.connection_host}] => (item=#{item_label})".colorize(:red)
            puts "  Message: #{ex.message}".colorize(:red)
            failed = true
            item_results << JSON::Any.new({"item" => item, "changed" => JSON::Any.new(false), "failed" => JSON::Any.new(true), "ansible_facts" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any)
            next
          end
          path = resolve_include_vars_path(task, candidate)

          unless path
            puts "failed: [#{host.connection_host}] => (item=#{item_label})".colorize(:red)
            puts "  Message: include_vars: file not found: #{candidate}".colorize(:red)
            failed = true
            item_results << JSON::Any.new({"item" => item, "changed" => JSON::Any.new(false), "failed" => JSON::Any.new(true), "ansible_facts" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any)
            next
          end

          loaded = begin
            RoleLoader.load_vars_file(path)
          rescue ex
            puts "failed: [#{host.connection_host}] => (item=#{item_label})".colorize(:red)
            puts "  Message: include_vars: could not parse #{path}: #{ex.message}".colorize(:red)
            failed = true
            item_results << JSON::Any.new({"item" => item, "changed" => JSON::Any.new(false), "failed" => JSON::Any.new(true), "ansible_facts" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any)
            next
          end

          store = (@included_vars[host.name] ||= Hash(String, JSON::Any).new)
          if name = task.include_vars_name
            store[name] = JSON::Any.new(loaded)
          else
            loaded.each { |key, value| store[key] = value }
          end
          @hv_generation += 1
          vars_context = item_context

          puts "ok: [#{host.connection_host}] => (item=#{item_label})".colorize(:green)
          executed = true
          item_results << JSON::Any.new({"item" => item, "changed" => JSON::Any.new(false), "failed" => JSON::Any.new(false), "ansible_facts" => JSON::Any.new(loaded)} of String => JSON::Any)
        end

        if register_name = task.register
          unless register_name.empty?
            @registered_vars[host.name][register_name] = JSON::Any.new({
              "changed" => JSON::Any.new(false),
              "failed"  => JSON::Any.new(failed),
              "results" => JSON::Any.new(item_results),
            } of String => JSON::Any)
            @hv_generation += 1
          end
        end

        if failed
          # Same ignore_errors: gap as finish_include_vars_failure's own
          # fix - a looped include_vars: (with_first_found:/loop:) that
          # fails on one of its items must count as ok+ignored under
          # ignore_errors:, not failed, matching real Ansible.
          if task.ignore_errors?
            @results[host.name]["ok"] += 1
            @results[host.name]["ignored"] += 1
          else
            @results[host.name]["failed"] += 1
            @halted_hosts.add(host.name)
          end
        elsif executed
          @results[host.name]["ok"] += 1
        else
          @results[host.name]["skipped"] += 1
        end
        return
      end

      begin
        return unless when_passes?(task, vars_context, host)
      rescue ex : WhenEvaluationError
        swallow_when_error(task, host, ex)
        return
      end

      # The file may be chosen by with_first_found (exposed as `item`) or
      # given directly; either way it is templated. strict: true inside
      # resolve_first_found (round174 matrix scenario 5b) can now raise
      # for a genuinely undefined candidate template - when: was already
      # checked above, so this is purely the loop-source failure.
      items = begin
        resolve_first_found(task, host, vars_context)
      rescue ex : UndefinedVariableError
        finish_include_vars_failure(task, host, ex.message || "is undefined")
        return
      end

      if items
        if items.empty?
          # Real Ansible's first_found lookup plugin defaults `skip:` to
          # false - with no candidate found, it raises ("The lookup
          # plugin 'first_found' failed: No file was found when using
          # first_found.") and the task FAILS, it does not silently skip.
          # `skip: true` (parsed into loop_first_found_skip) is the only
          # thing that makes real Ansible tolerate a miss. Found live
          # benchmarking robertdebock.release on Rocky 9.6: no `CentOS-9.
          # yml`/`Rocky-9.yml` vars file exists in the role at all - real
          # ansible-playbook correctly fails at "load release_packages";
          # this previously always skipped instead, silently continuing
          # past a role whose OS-specific package list was never loaded.
          if task.loop_first_found_skip?
            puts "skipping: [#{host.name}]".colorize(:cyan)
            @results[host.name]["skipped"] += 1
          else
            finish_include_vars_failure(task, host,
              "The lookup plugin 'first_found' failed: No file was found when using first_found.")
          end
          return
        end
        vars_context["item"] = items.first
        # loop_control: { loop_var: some_name } exposes the found
        # candidate under a CUSTOM name instead of (real Ansible: in
        # addition to) the default "item" - this dedicated with_
        # first_found: path only ever bound "item", the same gap
        # already fixed for the loop_items branch above (round165,
        # buluma.confluence) but missed here since with_first_found:
        # resolves through this separate branch entirely. arillso.*'s
        # own `include_vars: '{{ loop_vars }}'` with `loop_control:
        # loop_var: loop_vars` needs `loop_vars` bound to resolve at
        # all - without this it stayed undefined regardless of which
        # candidate file first_found actually matched, failing
        # "include_vars: file not found: undefined" on literally every
        # role sharing this idiom.
        if lv = task.loop_var
          vars_context[lv] = items.first
        end
      end

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      candidate = begin
        substitutor.scan_strict_include_vars_path(task.include_vars_file || "", task.vars)
        substitutor.substitute(task.include_vars_file || "", strict: true).strip
      rescue ex : UndefinedVariableError | FirstFoundLookupError
        # Real Ansible fails the include_vars task ITSELF when its path
        # template references an undefined variable ("Error while resolving
        # value for '_raw_params': 'users' is undefined", rc=2 - verified
        # live against 2.19.4 with a minimal repro), it does not render the
        # path to the literal text "undefined" and fail with "file not
        # found: undefined" (the old behavior, gantsign.oh-my-zsh round
        # 192's cosmetic-differences entry). Cause text only - real
        # Ansible's own "Finalization of task args ... failed: Error while
        # resolving value for '_raw_params':" wrapper is the same 2.19
        # presentation layer every other module's undefined-arg failure
        # already drops (see prepare_batch_step's identical rescue).
        finish_include_vars_failure(task, host, ex.message || "is undefined")
        return
      end
      path = resolve_include_vars_path(task, candidate)

      unless path
        finish_include_vars_failure(task, host, "include_vars: file not found: #{candidate}")
        return
      end

      loaded = begin
        RoleLoader.load_vars_file(path)
      rescue ex
        finish_include_vars_failure(task, host, "include_vars: could not parse #{path}: #{ex.message}")
        return
      end

      store = (@included_vars[host.name] ||= Hash(String, JSON::Any).new)
      if name = task.include_vars_name
        store[name] = JSON::Any.new(loaded)
      else
        loaded.each { |key, value| store[key] = value }
      end
      @hv_generation += 1

      # A non-looped `include_vars: ... register: some_var` - same
      # register: gap as the looped branch above, just the plain
      # (non-`.results`) shape real Ansible's own include_vars module
      # returns: `{ansible_facts: {...loaded...}, changed: false}`.
      if register_name = task.register
        unless register_name.empty?
          @registered_vars[host.name][register_name] = JSON::Any.new({
            "changed"       => JSON::Any.new(false),
            "failed"        => JSON::Any.new(false),
            "ansible_facts" => JSON::Any.new(loaded),
          } of String => JSON::Any)
          @hv_generation += 1
        end
      end

      puts "ok: [#{host.name}]".colorize(:green)
      @results[host.name]["ok"] += 1
    end

    # include_vars: with `dir:` - real Ansible's directory form
    # (lib/ansible/plugins/action/include_vars.py, verified live against
    # 2.19.4): loads every vars file under the directory, walking
    # subdirectories recursively by default (depth: 0 means UNLIMITED
    # levels - depth: 1 means top-level files only, each further level
    # adds one). Files load in sorted order (dirs traversed in sorted
    # path order), later files overriding earlier duplicate keys;
    # files_matching is a regex searched against the basename,
    # ignore_files is a list of regexes matched end-anchored against the
    # basename, and a file whose extension isn't in `extensions:` (the
    # default yaml/yml/json) FAILS the task unless
    # ignore_unknown_extensions: is true (real Ansible's default -
    # verified live: unknown extensions are a hard task failure, the
    # module's guard for skipping the role's own vars/main.yml is dead
    # code, so that file loads like any other). Same name:/register:
    # result shapes as the file: form above.
    private def execute_include_vars_dir(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Nil
      begin
        return unless when_passes?(task, vars_context, host)
      rescue ex : WhenEvaluationError
        swallow_when_error(task, host, ex)
        return
      end

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      raw_dir = task.include_vars_dir || ""
      candidate = begin
        substitutor.scan_strict_include_vars_path(raw_dir, task.vars)
        substitutor.substitute(raw_dir, strict: true).strip
      rescue ex : UndefinedVariableError
        finish_include_vars_failure(task, host, ex.message || "is undefined")
        return
      end

      dir = resolve_include_vars_dir_path(task, candidate)
      unless dir
        finish_include_vars_failure(task, host, "#{candidate} directory does not exist")
        return
      end
      unless File.directory?(dir)
        finish_include_vars_failure(task, host, "#{candidate} is not a directory")
        return
      end

      depth = 0
      if raw_depth = task.include_vars_depth
        depth_str = substitutor.substitute(raw_depth, strict: true).strip
        depth = depth_str.to_i?
        unless depth
          finish_include_vars_failure(task, host, "include_vars: invalid depth: #{depth_str}")
          return
        end
      end

      extensions = (task.include_vars_extensions || ["yaml", "yml", "json"]).map do |raw_ext|
        substitutor.substitute(raw_ext, strict: true).strip
      end

      files_matching = nil
      if raw_matching = task.include_vars_files_matching
        rendered = substitutor.substitute(raw_matching, strict: true).strip
        begin
          files_matching = Regex.new(rendered)
        rescue ex : ArgumentError
          finish_include_vars_failure(task, host, "Invalid regular expression: #{rendered}")
          return
        end
      end

      ignore_patterns = (task.include_vars_ignore_files || [] of String).map do |raw_pattern|
        rendered = substitutor.substitute(raw_pattern, strict: true).strip
        begin
          Regex.new(rendered + "$")
        rescue ex : ArgumentError
          finish_include_vars_failure(task, host, "Invalid regular expression: #{rendered}")
          return
        end
      end

      files = [] of String
      if err = collect_include_vars_dir_files(dir, depth, 1, extensions, files_matching,
        ignore_patterns, task.include_vars_ignore_unknown_extensions || false, files)
        finish_include_vars_failure(task, host, err)
        return
      end

      combined = Hash(String, JSON::Any).new
      files.each do |path|
        loaded = begin
          RoleLoader.load_vars_file(path)
        rescue ex
          finish_include_vars_failure(task, host, "include_vars: could not parse #{path}: #{ex.message}")
          return
        end
        loaded.each { |key, value| combined[key] = value }
      end

      store = (@included_vars[host.name] ||= Hash(String, JSON::Any).new)
      if name = task.include_vars_name
        store[name] = JSON::Any.new(combined)
      else
        combined.each { |key, value| store[key] = value }
      end
      @hv_generation += 1

      if register_name = task.register
        unless register_name.empty?
          @registered_vars[host.name][register_name] = JSON::Any.new({
            "changed"       => JSON::Any.new(false),
            "failed"        => JSON::Any.new(false),
            "ansible_facts" => JSON::Any.new(combined),
          } of String => JSON::Any)
          @hv_generation += 1
        end
      end

      puts "ok: [#{host.name}]".colorize(:green)
      @results[host.name]["ok"] += 1
    end

    # Depth-limited, sorted directory walk for dir:-mode include_vars: -
    # mirrors real Ansible's _traverse_dir_depth (walk results sorted by
    # root path, files within each dir sorted; depth 0 = unlimited, the
    # top dir itself is depth 1). `level` starts at 1 for the top dir.
    # Returns the first error message encountered, or nil when every
    # candidate file was accepted (matches are appended to `files`).
    private def collect_include_vars_dir_files(current : String, depth : Int32, level : Int32,
                                               extensions : Array(String), files_matching : Regex?,
                                               ignore_patterns : Array(Regex), ignore_unknown_extensions : Bool,
                                               files : Array(String)) : String?
      subdirs = [] of String
      Dir.children(current).sort.each do |entry|
        path = File.join(current, entry)
        if File.directory?(path)
          subdirs << path
          next
        end
        next if files_matching && !files_matching.matches?(entry)
        next if ignore_patterns.any?(&.matches?(entry))
        ext = File.extname(entry).lstrip('.')
        unless extensions.includes?(ext)
          # Real Ansible's default: an unknown-extension candidate file
          # fails the whole task - only ignore_unknown_extensions: true
          # skips it silently.
          next if ignore_unknown_extensions
          return "'#{path}' does not have a valid extension: #{extensions.join(", ")}"
        end
        files << path
      end
      return nil if depth != 0 && level >= depth
      subdirs.each do |sub|
        if err = collect_include_vars_dir_files(sub, depth, level + 1, extensions, files_matching,
          ignore_patterns, ignore_unknown_extensions, files)
          return err
        end
      end
      nil
    end

    # resolve_include_vars_path's directory counterpart - same search
    # roots (role vars/, the role root above it, the including file's
    # directory, the role root, the role's tasks/, the process cwd) but
    # accepts a path that EXISTS at the candidate (the caller then
    # distinguishes "missing" from "exists but not a directory", real
    # Ansible's own two distinct error messages).
    private def resolve_include_vars_dir_path(task : Task, candidate : String) : String?
      return File.exists?(candidate) ? candidate : nil if candidate.starts_with?("/")

      roots = [] of String
      if vars_dir = task.role_vars_dir
        roots << vars_dir
        roots << File.dirname(vars_dir)
      end
      task.include_file_dir.try { |dir| roots << dir }
      task.role_path.try { |role_dir| roots << role_dir }
      task.role_path.try { |role_dir| roots << File.join(role_dir, "tasks") }
      roots << Dir.current

      roots.each do |root|
        path = File.expand_path(candidate, root)
        return path if File.exists?(path)
      end
      nil
    end

    private def finish_include_vars_failure(task : Task, host : Host, message : String) : Nil
      puts "failed: [#{host.name}]".colorize(:red)
      puts "  Message: #{message}".colorize(:red)
      # ignore_errors: on a failed include_vars: - matching real
      # Ansible's own strategy/__init__.py, which counts this as `ok`
      # AND `ignored`, never `failed`, and never halts the host. Found
      # via CyVerse-Ansible.ez's own "include variables ..., if error,
      # just ignore" task (`ignore_errors: yes` on a missing-file
      # include_vars:): real Ansible's recap showed `ok=10 failed=0
      # ignored=1`, this engine's own unconditional `failed += 1` here
      # (the only include_vars: failure path that never consulted
      # ignore_errors: at all for its OWN stats, unlike every other
      # failure path in this file) showed `ok=9 failed=1 ignored=0`.
      if task.ignore_errors?
        @results[host.name]["ok"] += 1
        @results[host.name]["ignored"] += 1
      else
        @results[host.name]["failed"] += 1
        @halted_hosts.add(host.name)
      end
    end

    # RoleLoader's auto-synthesized "Validating arguments against arg
    # spec" task (see there) - checks the role's effective vars (already
    # in vars_context via role_defaults/role_vars, same as any other role
    # task) against each declared option's `required:`/`type:`, matching
    # real ansible-core's own role argument validation.
    private def execute_block(task : Task, host : Host) : Nil
      # Propagate role context BEFORE the when: check - the when-false
      # early-exit path prints each child's own "TASK [role : name]"
      # banner via print_skipped_tasks, which needs the child's
      # role_name to be set already (a skipped block's banners used to
      # lose their "role : " prefix because propagate ran only on the
      # executed path - 0x0i.systemd's "Broadcast uninstall signal" /
      # "Flush handlers" skipped-banner shape).
      propagate_role_context(task, task.block_tasks || [] of Task)

      if when_condition = task.when_condition
        vars_context = build_vars_context(task, host)
        when_result = false
        when_errored = false

        begin
          when_result = evaluate_when(when_condition, vars_context, host)
        rescue WhenEvaluationError
          # Real Ansible does NOT fail the block as a unit here. A
          # block's when: is inherited by each child task, so the SAME
          # failing condition is re-evaluated once per task: the first
          # task of block: fails on it (halting the rest of that list),
          # and then rescue: and always: still run, their own first
          # tasks failing the same way. Verified live against
          # ansible-core 2.19.12 (round173, Rocky 9.6): 2 block: + 2
          # always: tasks => failed=2 (only "block one" and "always
          # one" ever run); adding a rescue: => failed=2 rescued=1.
          # Emulated by pushing the condition down onto the children and
          # falling through to the normal flow below, so the standard
          # halt/rescue/always/rescued accounting applies unchanged.
          inherit_when_condition(when_condition, task.block_tasks)
          inherit_when_condition(when_condition, task.rescue_tasks)
          inherit_when_condition(when_condition, task.always_tasks)
          when_errored = true
        end

        unless when_errored || when_result
          # A block's when: is inherited by every task inside block: and
          # always: (verified against real ansible-playbook: each gets
          # its own "skipping: [host]" line and recap count, not one
          # aggregate line for the block) - rescue: is left alone since
          # it only ever runs if the block itself actually failed, which
          # can't happen when it never ran at all.
          print_skipped_tasks(task.block_tasks || [] of Task, host)
          print_skipped_tasks(task.always_tasks || [] of Task, host)
          return
        end
      end

      failed_before = @results[host.name]["failed"]
      # A block:'s own notify: (as opposed to notify: on one of its
      # nested tasks) fires once if ANY task inside the block/rescue/
      # always actually changed - real Ansible's own block-level notify
      # semantics. Previously entirely unhandled: only a regular task's
      # own notify: was ever forwarded to HandlerRunner. Found via
      # robertdebock.swap's own "Manage swap files." block (wraps
      # "Make a swap file"/"Make swap file system"/"Mount swap", none
      # of which have their own notify:) - "Run swapon" never fired.
      changed_before = @results[host.name]["changed"]
      run_task_list(task.block_tasks || [] of Task, host)
      block_failed = @halted_hosts.includes?(host.name)

      if block_failed && (rescue_tasks = task.rescue_tasks)
        @halted_hosts.delete(host.name)

        # The block-body failures move into "rescued" as soon as rescue:
        # is ENTERED - not only when the rescue then succeeds. Verified
        # live against ansible-core 2.19.12 (round173): a failing block
        # task plus a rescue: that ALSO fails recaps as
        # `failed=1 rescued=1`, not `failed=2` - the original body
        # failure is still rescued, and only the rescue's own failure
        # counts. Converting here (before running the rescue) keeps the
        # rescue's own failures counting normally afterwards.
        recovered = @results[host.name]["failed"] - failed_before
        if recovered > 0
          @results[host.name]["failed"] -= recovered
          @results[host.name]["rescued"] += recovered
        end

        propagate_role_context(task, rescue_tasks)
        run_task_list(rescue_tasks, host)
        block_failed = @halted_hosts.includes?(host.name)
      end

      if always_tasks = task.always_tasks
        @halted_hosts.delete(host.name)
        propagate_role_context(task, always_tasks)
        run_task_list(always_tasks, host)
        block_failed ||= @halted_hosts.includes?(host.name)
      end

      notify_hosts_if_changed(task, [host], {host.name => changed_before})

      @halted_hosts.delete(host.name)
      halt_if_failed(task, host, block_failed)
    end

    # Copy the *enclosing* task's role context (defaults/vars/dirs) into each
    # nested task. Used for block:/rescue:/always: nested lists and, via the
    # include_tasks path, for the tasks of an included file - in both cases
    # `nested_task` is a Task parsed independently of the enclosing one, so it
    # wouldn't otherwise know it belongs to a role. Without this, a
    # `template:`/`copy:` with a role-relative `src:` (e.g. os_hardening's
    # `src: etc/systemd/coredump.conf.d/coredumps.conf.j2`) fails to resolve
    # against the role's templates/, and role-default `when:` gates evaluate
    # undefined. Only fills gaps: defaults/vars already on the nested task win.
    private def propagate_role_context(enclosing : Task, nested_tasks : Array(Task)) : Nil
      nested_tasks.each do |nested_task|
        if (defaults = enclosing.role_defaults) && !defaults.empty?
          nested_task.role_defaults = defaults
        end
        if (role_vars = enclosing.role_vars) && !role_vars.empty?
          nested_task.role_vars = role_vars
        end
        nested_task.role_files_dir = enclosing.role_files_dir
        nested_task.role_templates_dir = enclosing.role_templates_dir
        nested_task.role_vars_dir = enclosing.role_vars_dir
        nested_task.role_path = enclosing.role_path
        nested_task.role_name = enclosing.role_name
        # An include_tasks: inside a dynamically include_role:'d role
        # belongs to the SAME invocation - meta: end_role in the included
        # file must end that same invocation, not fall back to the
        # role-path key (which a second include of the same role shares).
        nested_task.role_invocation_id = enclosing.role_invocation_id
        # RECURSE into nested block/rescue/always children: a when:-false
        # BLOCK is skipped in execute_task before execute_block's own
        # propagation ever runs, and its children's banners print via
        # print_skipped_tasks - without recursion they had no role_name
        # and lost their "role : " prefix (0x0i.systemd's "Broadcast
        # uninstall signal" / "Flush handlers" skipped banners; same
        # shape in kyl191.openvpn).
        propagate_role_context(nested_task, nested_task.block_tasks || [] of Task)
        propagate_role_context(nested_task, nested_task.rescue_tasks || [] of Task)
        propagate_role_context(nested_task, nested_task.always_tasks || [] of Task)
        # Same reasoning as role_loader.cr's own include_role_dir fix -
        # a nested include_role: reached via this include_tasks: must
        # still search from the playbook root, not this included file's
        # own directory (already wrongly baked into nested_task.
        # include_role_dir by the initial parse_task call).
        if include_role_dir = enclosing.include_role_dir
          nested_task.include_role_dir = include_role_dir
        end
        # ansible_parent_role_names - an include_tasks: inside a role
        # doesn't itself change the parent-role chain (only include_role:
        # pushes a new entry, in execute_include_role); a task reached
        # via include_tasks still belongs to the SAME role as its
        # enclosing task, so it inherits that role's own parent chain
        # unchanged. Without this, prometheus.prometheus's own
        # node_exporter role (whose own "Preflight" step is an
        # include_tasks:, not include_role:) lost its role_name/
        # role_parent_names for every task inside preflight.yml -
        # including the include_role: call to `_common` nested one level
        # further in, which then had no enclosing role context at all to
        # extend, so `_common`'s own direct-invocation guard assert
        # failed regardless of the real (indirect, via node_exporter)
        # invocation path.
        nested_task.role_parent_names = enclosing.role_parent_names
        nested_task.role_parent_paths = enclosing.role_parent_paths
        nested_task.ansible_collection_name = enclosing.ansible_collection_name

        # A block's own `vars:` is inherited by every task nested inside it
        # (real Ansible scoping) - found via linux-system-roles/logging's
        # `Check logging inputs` block, which computes `__logging_input_names:
        # "{{ logging_inputs | map(attribute='name') | list }}"` at the block
        # level and references it from a nested looped task's `when:`.
        # Without this, build_vars_context (which only ever reads a task's
        # *own* task.vars) never saw the block's vars at all, so
        # __logging_input_names resolved undefined - `intersect(undefined)`
        # returned empty, tripping the "includes undefined logging_inputs
        # item" fail: unconditionally. Merged so the nested task's own vars:
        # (if any) still win over the same key inherited from the block.
        unless enclosing.vars.empty?
          merged = enclosing.vars.dup
          nested_task.vars.each { |key, value| merged[key] = value }
          nested_task.vars = merged
        end
      end
    end

    # Runs a nested task list (block:/rescue:/always:), printing its own
    # TASK header per task since these live inside a block rather than the
    # play's top-level task list, so `run` never prints one for them. Stops
    # early once the host halts (a task failed without ignore_errors).
    private def execute_include_tasks(task : Task, host : Host) : Nil
      begin
        base_vars_context = build_vars_context(task, host)
      rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
        # Same degrade-to-one-clean-failed-task shape as the multi-host
        # execute_include_tasks_multi path's own build_vars_context
        # rescue: the include_tasks: statement's own `vars:` block used
        # an unknown filter, real Ansible fails just that include task
        # with "No filter named 'X'." instead of the whole process
        # crashing out of execute_task's include_tasks dispatch.
        swallow_when_error(task, host, WhenEvaluationError.new(ex.message || "Failed to render task vars"))
        return
      end
      # Must mirror the general task path's fallback chain (see the
      # equivalent block above execute_looped_task) - a bare `loop: "{{
      # var }}"` scalar-template loop on an include_tasks: (robertdebock.
      # users' own "Loop over users_groups"/"Loop over users") only ever
      # populated task.loop_items when the loop was written as a literal
      # YAML list. The template form fell through to the single-run
      # `else` branch below with no item bound at all, so a custom
      # loop_var like `group`/`user` resolved as "undefined" instead of
      # looping once per list entry.
      #
      # resolve_loop_items_or_raise: round174 matrix scenario 12a - a
      # genuinely undefined loop: source must fail this include_tasks:
      # task itself, BEFORE the included file is ever entered - real
      # Ansible never reaches the included task at all. swallow_when_error
      # below is the same task-level (no item_label) failure shape run_
      # include_tasks_once's own WhenEvaluationError rescue uses.
      begin
        loop_items = resolve_loop_items_or_raise(task, host, base_vars_context) do
          task.loop_items || resolve_first_found(task, host, base_vars_context) ||
            resolve_loop_template(task, base_vars_context) ||
            resolve_loop_nested(task, base_vars_context, host.name) ||
            resolve_loop_flattened(task, base_vars_context, host.name) ||
            resolve_loop_subelements(task, base_vars_context)
        end
      rescue ex : WhenEvaluationError
        swallow_when_error(task, host, ex)
        return
      end

      if loop_items
        # with_first_found:'s own no-candidate-matched, skip: true case -
        # resolve_first_found returns an empty (not nil) array for it,
        # matching execute_include_vars's identical handling of the same
        # situation.
        if loop_items.empty?
          puts "skipping: [#{host.name}]".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end

        # The item is exposed as `item` (Ansible's default) and, when
        # loop_control.loop_var is set, under that custom name too (e.g.
        # `mount` in dev-sec os_hardening's per-mountpoint include loop).
        loop_var = task.loop_var
        index_var = task.index_var
        if task.loop_items_needs_flatten?
          # with_items:'s implicit flatten(levels=1) needs each raw item
          # RENDERED first (a raw item here is still an unrendered "{{
          # default_directories }}"-style template string, not yet the
          # real array it resolves to) - flatten only makes sense against
          # the rendered values.
          loop_items = flatten_with_items_one_level(
            loop_items.map { |item| deep_render_item(item, base_vars_context, host.name, strict: false) }
          )
        end
        loop_items.each_with_index do |item, idx|
          vars_context = base_vars_context.dup
          # Render any string field of the item that is itself a template
          # (e.g. dev-sec os_hardening's mount-list entries: `enabled:
          # "{{ os_mnt_tmp_enabled }}"`) before binding it into scope -
          # otherwise a bare `when: mount.enabled | bool` (no outer
          # `{{ }}` for ConditionalEvaluator to render through) sees the
          # literal unrendered "{{ os_mnt_tmp_enabled }}" text, which the
          # `bool` filter treats as truthy regardless of the real value.
          rendered_item = deep_render_item(item, vars_context, host.name, strict: false)
          vars_context["item"] = rendered_item
          vars_context[loop_var] = rendered_item if loop_var
          vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
          # Each include_tasks loop iteration counts as one `ok` in the
          # recap, matching real Ansible (which tallies the include plus
          # every included task per iteration) - but only once the
          # include's own when: (checked inside run_include_tasks_once,
          # since it may reference this iteration's `item`) actually
          # passes. The increment used to happen unconditionally here,
          # before that check ran - a when:-gated include_tasks: that
          # ultimately skipped still got counted as `ok` AND `skipped`
          # for the same task. See the non-looped branch's comment below
          # for how this was found.
          run_include_tasks_once(task, host, vars_context, item_display(item))
        end
      else
        # Non-looped include_tasks: itself counts as one `ok` in the
        # recap too, matching real Ansible - the looped branch above
        # already credits this per iteration, but a plain (unlooped)
        # include_tasks: never did, undercounting the recap's `ok=`
        # tally by exactly 1 versus real Ansible for every such task.
        # Found benchmarking robertdebock.openvpn's own "Setup openvpn
        # server or client" (a single, non-looped include_tasks:) -
        # functionally harmless (the included tasks all still ran
        # correctly) but a real, easily reproduced recap-count
        # divergence.
        #
        # The increment itself moved into run_include_tasks_once (after
        # its own when: check passes) rather than staying here
        # unconditionally - robertdebock.openssl's own looped `include_
        # tasks: create.yml` (loop: "{{ openssl_items }}", gated by
        # `when: openssl_items is defined`) falls into THIS branch when
        # openssl_items is undefined (the loop can't resolve, so
        # loop_items above is nil) and was being counted as both `ok`
        # and `skipped` for the same single skipped include - crediting
        # `ok` here unconditionally, then run_include_tasks_once's own
        # when:-false path adding `skipped` on top, with no when: check
        # in between.
        run_include_tasks_once(task, host, base_vars_context, nil)
      end
    end

    private def run_include_tasks_once(task : Task, host : Host, vars_context : Hash(String, JSON::Any), item_label : String?) : Nil
      if when_condition = task.when_condition
        begin
          when_result = evaluate_when(when_condition, vars_context, host)
        rescue ex : WhenEvaluationError
          swallow_when_error(task, host, ex, item_label: item_label)
          return
        end

        unless when_result
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = item_label ? " => (item=#{item_label})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
      end

      # The include itself counts as one `ok` (see the two call sites'
      # own comments) - only reached once the when: check above has
      # actually passed.
      @results[host.name]["ok"] += 1

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      file_rel = substitutor.substitute(task.include_file.as(String))
      resolved_path = PlaybookParser.resolve_include_path(file_rel, task.include_file_dir.as(String))

      unless File.exists?(resolved_path)
        fail_include(task, host, "Included tasks file not found: #{resolved_path}")
        return
      end

      yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
      # A comment-only (or entirely blank) tasks file - see the batched
      # #execute_include_tasks_multi path's identical check for why this
      # can't be folded into the `unless yaml.as_a?` check below.
      return if yaml.raw.nil?
      unless yaml.as_a?
        fail_include(task, host, "Included tasks file must be a YAML list: #{resolved_path}")
        return
      end

      inherited = Play.new("", "")
      inherited.become = task.become?
      inherited.become_user = task.become_user
      included_tasks = PlaybookParser.parse_tasks(yaml.as_a, inherited, "task in included #{resolved_path}", File.dirname(resolved_path), role_path: task.role_path, playbook_dir: @playbook_dir)

      # Role context (role_name/defaults/vars/dirs) must reach the
      # included tasks on THIS path too: an include_tasks: inside a role
      # executed for a single host (or --forks 1) never ran
      # propagate_role_context, so the included tasks - and everything
      # nested inside them, e.g. a block's children - had no role_name,
      # and their banners lost the "role : " prefix (0x0i.systemd's
      # skipped "Broadcast uninstall signal"/"Flush handlers"; same
      # shape in kyl191.openvpn). The multi-host include path
      # (execute_include_tasks_multi) already propagates - this mirrors
      # it.
      propagate_role_context(task, included_tasks)

      # Propagate this iteration's loop `item` and the include statement's
      # own vars: into each included task's own scope: run_task_list ->
      # execute_task rebuilds a fresh vars_context per task from scratch
      # (play/host/registered/task vars), which wouldn't otherwise see
      # either of these.
      if include_vars = task.include_vars
        included_tasks.each do |included_task|
          include_vars.each { |key, value| included_task.vars[key] = value }
        end
      end

      # Thread this iteration's item into each included task's own scope as
      # `item` and, when loop_control.loop_var is set, under that custom name
      # too (so `mount.path` in a name/param/when: resolves). The banner's
      # own rendering of a name referencing these happens lazily at print
      # time - see the note further below.
      if item = vars_context["item"]?
        included_tasks.each do |included_task|
          included_task.vars["item"] = item
          if loop_var = task.loop_var
            included_task.vars[loop_var] = item
          end
          # loop_control.index_var (e.g. riemers.gitlab-runner's own
          # `index_var: runner_config_index`) was never propagated here -
          # only loop_var/item were. The include_tasks: task's own vars:/
          # name still resolved it fine (both render against vars_context
          # directly, which DOES have it bound a few lines up), but any
          # included task referencing it directly (config-runner.yml's own
          # `prefix: gitlab-runner.{{ runner_config_index }}.`) saw
          # "'runner_config_index' is undefined" instead.
          if (index_var = task.index_var) && (bound = vars_context[index_var]?)
            included_task.vars[index_var] = bound
          end
        end
      end
      # NOTE: the included tasks' own `name:` strings are deliberately NOT
      # pre-substituted here anymore. The old eager pass baked every name
      # once at include-entry time, against a context that had this
      # iteration's `item` but none of the FACTS the included file's own
      # earlier tasks go on to set (systemli.apt_repositories' repo.yml:
      # "Add key by content for {{ _name }}", where `_name` comes from two
      # set_fact: tasks earlier in the SAME iteration) - every such name
      # baked to a permanent "... for undefined" banner, while the same
      # task's params rendered fine. Banners now render lazily at print
      # time (render_task_name_for_display -> build_vars_context), which
      # sees both the threaded `item`/loop_var (into task.vars, just above)
      # and any facts set mid-iteration - matching real Ansible, which
      # templates each task's name at ITS OWN task-start with current
      # task_vars (verified live against ansible-core 2.19.4).

      # Propagate the *role* context (defaults/vars/dirs) into each included
      # task. Included files - especially a role's task files like
      # dev-sec os_hardening's hardening.yml - gate their own imports on
      # role-default variables (e.g. `when: os_auditd_enabled | bool`).
      # Without this, an include_tasks: inside a role produced tasks with no
      # role_defaults, so every one of those gates resolved as undefined
      # (false) and the whole role silently skipped. Mirror the way `vars:`
      # and `item` are threaded through above. role_defaults/role_vars here
      # carry the *role's* own scope (not the include statement's inline
      # vars:, which is handled above), matching real Ansible where an
      # included file shares the enclosing role's defaults/vars.
      propagate_role_context(task, included_tasks)

      run_task_list(included_tasks, host)
    rescue ex : HandlerNotFoundError
      # Same as the batched include path above - see there.
      raise ex
    rescue ex
      fail_include(task, host, "Failed to load included tasks: #{ex.message}")
    end

    private def fail_include(task : Task, host : Host, message : String) : Nil
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      puts "failed: [#{connection_host}]".colorize(:red)
      puts "  #{message}".colorize(:red)
      # Same ignore_errors: stats fix as finish_include_vars_failure -
      # a broken include_tasks:/include_role:/import_* (missing file,
      # bad YAML shape, load error) under ignore_errors: counts as
      # ok+ignored, not failed, matching real Ansible. halt_if_failed
      # already correctly skips halting under ignore_errors: - this
      # method's own stats increment never did.
      if task.ignore_errors?
        @results[host.name]["ok"] += 1
        @results[host.name]["ignored"] += 1
      else
        @results[host.name]["failed"] += 1
      end
      halt_if_failed(task, host, true)
    end

    # Runs an include_role: task - the dynamic counterpart to a roles:
    # list entry. Task-level keywords (when:/tags:/loop:) apply to the
    # include_role statement itself, same as include_tasks.
    # meta: clear_facts - drops this host's gathered facts. Under
    # --gathering smart that's the escape hatch: @facts is the shared
    # run-scoped store, so emptying this host's entry makes the *next*
    # play's gather_facts_for_all_hosts see it as ungathered and query it
    # again. Under the default implicit mode every play re-gathers
    # anyway, so this just clears facts for the remainder of this play.
    #
    # Matches real ansible-playbook, verified against ansible-core 2.19.4:
    # under gathering=smart, a `meta: clear_facts` in play 2 causes play 3
    # to re-run Gathering Facts.
    # Produces no per-host output line and does not count toward the
    # recap, matching ansible-core 2.19.4: its `TASK [clear]` banner
    # prints with no `ok:` beneath it, and the meta task is absent from
    # the play recap's ok= total.
    private def execute_include_role(task : Task, host : Host) : Nil
      begin
        base_vars_context = build_vars_context(task, host)
      rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
        # Same degrade-to-one-clean-failed-task shape as the include_
        # tasks paths' own build_vars_context rescues: the include_role:
        # statement's own `vars:` block used an unknown filter, real
        # Ansible fails just that include task with "No filter named
        # 'X'." instead of the whole process crashing out of execute_
        # task's include_role dispatch.
        swallow_when_error(task, host, WhenEvaluationError.new(ex.message || "Failed to render task vars"))
        return
      end
      # Same scalar-template loop gap as execute_include_tasks above.
      #
      # resolve_loop_items_or_raise: round174 matrix scenario 12b - same
      # class of gap/fix as execute_include_tasks just above (real
      # Ansible never enters the role at all on an undefined loop:
      # source).
      begin
        loop_items = resolve_loop_items_or_raise(task, host, base_vars_context) do
          task.loop_items ||
            resolve_loop_template(task, base_vars_context) ||
            resolve_loop_nested(task, base_vars_context, host.name) ||
            resolve_loop_flattened(task, base_vars_context, host.name) ||
            resolve_loop_subelements(task, base_vars_context)
        end
      rescue ex : WhenEvaluationError
        swallow_when_error(task, host, ex)
        return
      end

      if loop_items
        loop_var = task.loop_var
        index_var = task.index_var
        if task.loop_items_needs_flatten?
          loop_items = flatten_with_items_one_level(
            loop_items.map { |item| deep_render_item(item, base_vars_context, host.name, strict: false) }
          )
        end
        loop_items.each_with_index do |item, idx|
          vars_context = base_vars_context.dup
          vars_context["item"] = item
          vars_context[loop_var] = item if loop_var
          vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
          run_include_role_once(task, host, vars_context, item_display(item))
        end
      else
        run_include_role_once(task, host, base_vars_context, nil)
      end
    end

    private def run_include_role_once(task : Task, host : Host, vars_context : Hash(String, JSON::Any), item_label : String?) : Nil
      # A static import_role: (Task#is_static_import) is resolved at
      # parse time in real Ansible - the import line itself produces NO
      # task result at all, ever (see the "ok" comment below), and a
      # `when:` on the import is combined onto EVERY task the role
      # expands to, not evaluated once against the import as a whole.
      # So a `when: false` import_role: must still load and expand the
      # role's tasks - each shows its own "TASK [...]"/"skipping:"
      # banner under its own real name - rather than being treated as
      # one atomic no-op with nothing printed at all. Found via
      # brunobenchimol.certbot_dns (round855): real Ansible's recap
      # showed every one of geerlingguy.certbot's own tasks individually
      # skipped (`TASK [geerlingguy.certbot : Symlink certbot into
      # place.]` / `skipping:`, etc.) where this engine printed nothing
      # for that import at all, undercounting `skipped` by the role's
      # entire task count.
      #
      # A DYNAMIC include_role: (not static) keeps the old behavior
      # unchanged - real Ansible's own IncludeRole task DOES produce a
      # single result of its own when its `when:` is false, so returning
      # early with one "skipping:" line for the include_role: task
      # itself is correct there (see the "ok" comment below for the
      # sibling true-branch rationale).
      if (when_condition = task.when_condition) && !task.is_static_import?
        begin
          when_result = evaluate_when(when_condition, vars_context, host)
        rescue ex : WhenEvaluationError
          swallow_when_error(task, host, ex, item_label: item_label)
          return
        end

        unless when_result
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = item_label ? " => (item=#{item_label})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
      end

      # The include_role: task itself counts as one `ok` in the recap,
      # matching real Ansible (verified against ansible-core 2.19.4's
      # own strategy/__init__.py: an IncludeRole result still hits the
      # same `self._tqm._stats.increment('ok', ...)` as a plain task) -
      # same fix already applied to execute_include_tasks's
      # run_include_tasks_once (see its own comment) but never mirrored
      # here. Placed after the when: check, like that one, so a
      # when:-gated include_role: that skips isn't double-counted as
      # both `ok` and `skipped`. Found benchmarking andrewrothstein.
      # terraform (round 154 v3): real Ansible's cold-run recap was
      # `ok=12`, crystal's was `ok=10` - both `include_role:` calls in
      # the role (andrewrothstein.hashi, andrewrothstein.unarchivedeps)
      # were silently undercounted despite running correctly.
      #
      # NOT applied for a static import_role: (Task#is_static_import) -
      # real Ansible's own IncludeRole result/stats increment only fires
      # for the genuinely dynamic include_role:; import_role: is resolved
      # at parse time and produces no task result of its own at all (see
      # is_static_import's own comment - found via round171's
      # robertdebock.revealmd).
      #
      # Incremented AFTER the role actually loads (see the `rescue` below),
      # not here - counting it eagerly double-counted a role that fails to
      # load at all (nonexistent role name): both this "ok" AND
      # fail_include's own "failed" fired for the same task. Found round185
      # benchmarking andrewrothstein.libvirt (a broken meta dependency on
      # the since-removed andrewrothstein.qemu): real Ansible's recap was
      # `ok=0 failed=1` (a fatal, unrescued include_role halts the play for
      # that host immediately, same as any other fatal task), crystal's was
      # `ok=1 failed=1`.

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      role_name = substitutor.substitute(task.include_role_name.as(String))

      inherited = Play.new("", "")
      inherited.become = task.become?
      inherited.become_user = task.become_user

      # ansible_parent_role_names: the ancestor role-name chain leading to
      # THIS include_role: call - if this include_role task itself
      # belongs to another role's tasks (task.role_name set), the loaded
      # role's own parent chain is that enclosing role's own parent
      # chain plus the enclosing role's own name.
      child_parent_names = (task.role_parent_names || [] of String) + (task.role_name ? [task.role_name.as(String)] : [] of String)
      child_parent_paths = (task.role_parent_paths || [] of String) + (task.role_path ? [task.role_path.as(String)] : [] of String)
      # task.role_defaults already represents the FULL accumulated
      # ancestor-chain default set (RoleLoader#load_role merges
      # parent_defaults into it before assigning), not just this role's
      # own defaults/main.yml - so simply forwarding it here propagates
      # the whole chain, same accumulate-not-replace approach as
      # child_parent_names/child_parent_paths above. See RoleLoader#
      # load_role's own comment on why this needs to happen at all.
      child_parent_defaults = task.role_defaults || Hash(String, JSON::Any).new

      rendered_include_vars = render_include_role_vars(task.include_role_vars, vars_context, host.name)

      begin
        included_tasks, included_handlers = RoleLoader.load_single_role(
          role_name,
          rendered_include_vars,
          task.tags,
          inherited,
          task.include_role_dir.as(String),
          task.include_role_tasks_from,
          child_parent_names,
          child_parent_paths,
          child_parent_defaults
        )
      rescue ex : UnresolvedModuleError
        # Same bypass as HandlerNotFoundError's - an include_role:'d
        # role whose own tasks name a module real Ansible can't resolve
        # anywhere aborts the whole run (real Ansible's playbook-load
        # check), rather than degrading to a per-task
        # "Failed to load role" failure. See UnresolvedModuleError's
        # own comment for the graceful/hard-stop boundary.
        raise ex
      rescue ex
        fail_include(task, host, "Failed to load role '#{role_name}': #{ex.message}")
        return
      end

      # Same parent-when-PREPENDED propagation import_tasks: already
      # applies to its own flattened tasks (playbook_parser.cr's
      # try_parse_import_tasks - see that code's own comment on why
      # prepended, not appended, matters for short-circuit evaluation
      # order) - import_role: needed the identical fix, applied here at
      # runtime since (unlike import_tasks:, resolved fully at parse
      # time) the role's tasks aren't loaded until this include_role:
      # task actually executes.
      if task.is_static_import? && (import_when = task.when_condition)
        # Handlers are deliberately excluded: they're only ever executed
        # when notified via flush_handlers, not gated by whatever
        # skipped the import itself - propagating the import's when:
        # onto a handler DEFINITION would be a behavior real Ansible
        # doesn't have, not a fix for anything seen live.
        included_tasks.each do |included_task|
          included_task.when_condition = included_task.when_condition ? "(#{import_when}) and (#{included_task.when_condition})" : import_when
        end
      end

      @results[host.name]["ok"] += 1 unless task.is_static_import?

      # Round 26 originally had an eager re-render of each loaded task's
      # `name:` here (against just the include_role: `vars:` passed in) to
      # fix a role's tasks/main.yml `name: "Create group {{ _child_group
      # }}"` staying literal in the "TASK [...]" banner - found via
      # prometheus.prometheus.alertmanager's own `_common` role include
      # (`_common_system_group: "{{ alertmanager_system_group }}"` passed
      # as include_role vars:). That eager pass is now not just redundant
      # but actively harmful: `render_task_name_for_display` (0.9.353)
      # already re-renders every task name lazily, right before print,
      # against the task's own FULL vars_context (role defaults/vars +
      # magic vars + include_role vars - everything, not just what this
      # one include_role: call happened to pass). This eager pass's own
      # context was always a strict subset of that (missing the newly-
      # loaded role's own vars/main.yml entries and its
      # ansible_parent_role_names/ansible_collection_name magic vars,
      # neither available until the task actually executes) - fine for a
      # name referencing ONLY an explicitly-passed include_role var (round
      # 26's case), but for a name referencing anything else (round 28's
      # `_common_service_name`, computed internally by _common's own
      # vars/main.yml from `ansible_parent_role_names`/
      # `ansible_collection_name` - never passed as an include_role var at
      # all) the substitution failed to "undefined" and PERMANENTLY BAKED
      # THAT WRONG VALUE into `t.name`, since `render_task_name_for_display`
      # only re-renders a name that still contains `{{` - "undefined" has
      # none, so the later, correct, full-context render never got a
      # chance to run. Found live via prometheus.prometheus.pushgateway's
      # own "Create systemd service unit {{ _common_service_name }}" task
      # (round 28) - reproduced by inserting a probe task right before it:
      # the probe's own BODY correctly resolved `_common_service_name` to
      # "pushgateway" via the exact same vars_context machinery, proving
      # the value was never actually unavailable - only this eager,
      # narrower pre-render had gotten there first and gotten it wrong.

      # One fresh invocation identity per run_include_role_once call -
      # per host, per loop item - what meta: end_role keys its per-host
      # flag on (see Task#role_invocation_id).
      invocation_id = Random::Secure.hex(8)
      (included_tasks + included_handlers).each do |included_task|
        included_task.role_invocation_id = invocation_id
      end

      if item = vars_context["item"]?
        (included_tasks + included_handlers).each do |included_task|
          included_task.vars["item"] = item
          if (loop_var = task.loop_var) && (bound = vars_context[loop_var]?)
            included_task.vars[loop_var] = bound
          end
          # Same index_var propagation gap as run_include_tasks_once's
          # identical fix above.
          if (index_var = task.index_var) && (bound = vars_context[index_var]?)
            included_task.vars[index_var] = bound
          end
        end
      end

      # flatten_handler_blocks: a dynamically include_role:'d role can
      # equally define a block:-wrapped handler in its own
      # handlers/main.yml - same expansion the play's own static
      # handlers get in #initialize, needed here too since this is the
      # other (and only other) place a block-type Task can enter
      # @handler_runner's flat handler list.
      @handler_runner.handlers.concat(flatten_handler_blocks(included_handlers)) unless included_handlers.empty?

      run_task_list(included_tasks, host)
    end

    # Recursively renders every string field of a loop item that is
    # itself a template (Hash/Array values are walked; a String
    # containing "{{" is substituted through *vars_context*, everything
    # else is returned unchanged) - see execute_include_tasks for why
    # this matters for bare (non-`{{ }}`) when: conditions.
    private def resolve_role_relative_src(task : Task, params : Hash(String, String)) : Hash(String, String)
      src = params["src"]?
      return params if src.nil? || src.starts_with?('/')

      # synchronize (ansible.posix) shares the copy:/assemble: files/-
      # dir dwim (real Ansible's own _get_absolute_path resolves a
      # relative synchronize path against the role's files/). The
      # remote-path guard matters ONLY for synchronize - pull mode's
      # src: (and an explicit user@host:path anywhere) is an rsync
      # remote spec, not a controller-relative path - but a ':' in a
      # copy:/template: src is meaningless anyway, so the guard is
      # unconditional.
      return params if src.includes?(':') || src.starts_with?("rsync://")

      subdir = case task.module_name
               when "ansible.builtin.copy"     then "files"
               when "ansible.builtin.template" then "templates"
               when "ansible.builtin.assemble" then "files"
               when "ansible.posix.synchronize" then "files"
               else                                 nil
               end
      return params unless subdir

      role_dir = case task.module_name
                 when "ansible.builtin.copy"     then task.role_files_dir
                 when "ansible.builtin.template"
                   # No templates/ dir at all: real Ansible's own search
                   # list for a relative template: src: goes from
                   # <role>/templates/<src> straight to <role>/<src> (the
                   # ROLE ROOT - verified against ansible-core 2.19's
                   # "Searched in:" list; it does NOT search role files/).
                   # A role that keeps everything under files/templates/
                   # (alivx.ansible_cis_nginx_hardening's
                   # src: "files/templates/nodejs.conf") resolves via that
                   # role-root candidate, so without this the
                   # role_templates_dir-nil guard below returned params
                   # unresolved and the task failed with "Template file
                   # not found on controller" where real ansible-playbook
                   # changed the file.
                   task.role_templates_dir || task.role_path
                 when "ansible.builtin.assemble" then task.role_files_dir
                 when "ansible.posix.synchronize" then task.role_files_dir
                 else                                 nil
                 end
      return params unless role_dir

      # Real Ansible searches a role task's ENTIRE parent-role chain for
      # a relative src:, not just the currently-executing role's own
      # files:/templates: dir - a shared/generic role commonly relies on
      # this to let each CALLING role supply its own asset under the
      # same relative name (prometheus.prometheus's own `_common` role,
      # invoked by every exporter role: `src: "{{ _common_service_name
      # }}.service.j2"` resolves to `node_exporter/templates/node_
      # exporter.service.j2` when invoked FROM node_exporter, not to
      # any file inside _common's own templates/ dir at all). Checked
      # nearest-parent-first (role_parent_paths is root-first, so
      # reversed here), falling back to the current role's own dir
      # unchanged (even if the file doesn't exist there either) so the
      # existing "not found" error still names the expected location.
      candidate = File.join(role_dir, src)
      # Some roles bake the subdir prefix into src: itself (buluma.
      # confluence's own `src: "./templates/opt/atlassian/confluence/
      # bin/setenv.sh.j2"` - "templates/" already there, meant to
      # resolve against the ROLE ROOT, not role_templates_dir/role_
      # files_dir again) - the same "prefix already baked in" idiom
      # already handled for first_found's own paths: entries
      # (ExpressionEvaluator#resolve_first_found_roots). Without this,
      # `File.join(role_dir, src)` doubled the subdir
      # (".../templates/templates/opt/...", never existing), while real
      # ansible-playbook correctly resolves it against the role root.
      # Tried only as a fallback (role_dir/src checked first, matching
      # every existing role using the plain "opt/atlassian/..." form
      # without the prefix) so neither idiom regresses the other.
      unless File.exists?(candidate)
        role_root_candidate = task.role_path.try { |root| File.join(root, src) }
        candidate = role_root_candidate if role_root_candidate && File.exists?(role_root_candidate)
      end
      unless File.exists?(candidate)
        if parent_paths = task.role_parent_paths
          parent_paths.reverse_each do |parent_path|
            parent_candidate = File.join(parent_path, subdir, src)
            if File.exists?(parent_candidate)
              candidate = parent_candidate
              break
            end
          end
        end
      end

      # Must be absolute: #inline_copy_source_content's own "is this a
      # real controller-side path that needs staging to a remote host"
      # gate is `src.starts_with?('/')` - a relative candidate (which
      # this always was whenever krikri-playbook is invoked with a
      # relative playbook path, the common case) silently skipped that
      # gate entirely, leaving `src:` as an unresolved relative string
      # in the params sent to copy.cr's plugin binary - which runs ON
      # THE REMOTE HOST, where that relative path never existed. Found
      # via robertdebock.dns's "Place override.conf" (a role-relative
      # copy: src: reached over a real SSH connection, previously
      # untested - every prior copy:-with-role-relative-src: round used
      # either remote_src: true or a local connection).
      resolved = params.dup
      resolved["src"] = File.expand_path(candidate)
      resolved
    end

    # copy.cr runs on the *target* host (uploaded there like every other
    # plugin, unlike template: - an action plugin that runs on the
    # controller and already handles this correctly by reading its own
    # src: file locally before dispatch). A copy: task's `src:` names a
    # file on the *controller*, so copy.cr's own `File.exists?(src)`
    # check - a plain local filesystem check, from the perspective of
    # wherever it's actually running - can never find it once the play
    # targets a genuinely remote host: the file was never transferred
    # there. Found via konstruktoid-hardening's "Add cracklib password
    # list" (its only `copy:` task with a real src: file, previously
    # entirely untested territory) - failed with "Source file not found"
    # citing the exact real (and really-existing-on-the-controller) path.
    #
    # Read here, on the controller, and forwarded as `content:` instead -
    # copy.cr already has a fully-working content-write path (used by
    # any `copy: {content: ..., dest: ...}` task), so this reuses it
    # rather than needing a separate upload mechanism. Left alone for
    # `remote_src: true` (real Ansible's own remote-to-remote copy,
    # where src: already refers to a path on the target, not the
    # controller - reading it here would be wrong) and for a local
    # connection (copy.cr already runs on the same filesystem as the
    # controller in that case, so src: already resolves correctly as-is -
    # converting it anyway would only change check-mode's message
    # ("Would copy SRC to DEST" -> a generic content message) for no
    # actual correctness gain).
    # Above this size, embedding the file as a `content` param string
    # would make the JSON config too large to safely round-trip through
    # #execute_remote_plugin's own base64 encoding of the *whole config*
    # (see the comment on that call): a real bug found benchmarking
    # ansible-community.ansible-vault's own "Install Vault" task, which
    # `copy:`s a ~530MB downloaded Vault release binary - Crystal
    # stdlib's `Base64.encode_size` computes `str_size * 4` as native
    # Int32 arithmetic before the final `.to_i`, and a base64'd-then-
    # JSON-escaped-then-base64'd-again 530MB payload comfortably clears
    # 2^31, crashing the whole engine with an unhandled OverflowError
    # partway through a run - not a graceful per-task failure.
    INLINE_COPY_MAX_BYTES = 8 * 1024 * 1024
  end
end
