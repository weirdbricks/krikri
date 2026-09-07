require "./executor"

module Krikri
  class TaskExecutor
    private def task_has_loop?(task : Task) : Bool
      !task.loop_items.nil? || !task.loop_fileglob.nil? || !task.loop_first_found.nil? ||
        !task.loop_template.nil? || !task.loop_flattened.nil? || !task.loop_subelements_list.nil?
    end

    # Runs *tasks* against *hosts* as one shared batch: one "TASK [...]"
    # banner per task, fanned out across every currently-active host via
    # the same forkable/parallel path #run always used at the top level -
    # not resolved and re-run host-by-host in full serial passes. This is
    # the single engine behind both the play's own top-level task list
    # AND any nested list reached via include_tasks:/block:/rescue:/
    # always: (previously two different code paths: the top-level loop
    # here, and the single-host-only run_task_list/execute_include_tasks/
    # execute_block trio below, still kept as-is and still used for the
    # narrower cases this method defers to them for - a looped
    # include_tasks:, or any task reached via some other single-host
    # call site).
    #
    # Real bug found benchmarking a real 2-node geerlingguy.kubernetes
    # cluster bring-up (round 37, 0.9.383): geerlingguy.containerd/
    # geerlingguy.kubernetes both gate their OS-family setup via
    # `include_tasks: setup-Debian.yml` - an extremely common Ansible
    # idiom, not specific to these two roles. Every task previously
    # reached through execute_include_tasks's single-host run_task_list
    # ran against host 1 *to completion*, then host 2 *to completion*,
    # serially - never overlapping their SSH round trips or remote
    # command time despite `--forks` otherwise being available, because
    # include_tasks: itself was excluded from task_forkable? and the
    # tasks reached through it were dispatched one whole host at a time
    # regardless. Measured as a consistent ~1.8x cold-run wall-time
    # regression on a real 2-host cluster playbook (apt installs,
    # kubeadm image pulls) across two independent host pairs
    # (247.4s/252.1s vs a stable ~137s/135s for real ansible-playbook on
    # the same playbook) - not host-to-host jitter, since both engines'
    # own repeated measurements were reproducible within ~2%.
    # --step: ask before each task. Real ansible-playbook prompts
    # "Perform task: TASK: <name> (N)o/(y)es/(c)ontinue: " and treats
    # anything other than y/c as No (the capital N is the default), with
    # `c` disabling every later prompt for the rest of the run. Answering
    # No skips the task outright - it does not run and is not counted.
    #
    # Not reproduced: real Ansible prints the prompt line TWICE, once
    # plain and once padded out with asterisks, which is an artifact of
    # routing it through its display banner rather than intended output.
    @step_continue = false

    private def resolve_with_file(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : Array(JSON::Any)?
      entries = task.loop_file
      return nil unless entries

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      role_path = vars_context["role_path"]?.try(&.as_s?)
      paths = [] of String

      entries.each do |entry|
        substituted = substitutor.substitute(entry, strict: true)

        if substituted.starts_with?('[')
          parsed = (JSON.parse(substituted).as_a? rescue nil)
          if parsed
            paths.concat(parsed.map(&.to_s))
            next
          end
        end

        paths << substituted
      end

      paths.map do |path|
        resolved = path.starts_with?('/') || !role_path ? path : File.join(role_path, "files", path)
        begin
          JSON::Any.new(File.read(resolved).chomp)
        rescue
          raise WhenEvaluationError.new("Unable to access the file '#{resolved}': not found")
        end
      end
    end

    # Resolve a loop:/with_items:/with_dict:/with_nested:/with_indexed_items:
    # given as "{{ some_var }}" against the runtime variable context, then
    # feed it through the same conversion each keyword uses for a literal
    # value at parse time (see PlaybookParser#parse_task).
    private def resolve_loop_template(task : Task, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      kind = task.loop_template_kind
      template = task.loop_template
      return nil unless kind && template

      value = resolve_template_value(template, vars_context)

      # A complex template - `with_items: "{{ some_list | default([]) |
      # map(attribute='path') | difference(another | list) }}"` (used by
      # dev-sec os_hardening's yum gpg-check tasks) - isn't a plain variable
      # reference, so resolve_template_value returns nil. Evaluate it as a
      # filter chain via ExpressionEvaluator instead, then parse the
      # resulting (possibly empty) list into loop items. Without this the
      # loop resolved to nil, the task ran once, and `item` was the literal
      # `{{ ... }}` template string.
      unless value
        # Strip any {{ }} wrapper around the template expression, then
        # hand the bare expression to the filter-chain evaluator.
        bare = template.strip
        if bare.starts_with?("{{") && bare.ends_with?("}}")
          bare = bare[2..-3].strip
        end
        # A loop source whose value is undefined but which passes
        # through a filter first (`loop: "{{ environment_list |
        # dict2items }}"`, buluma.environment) never reached
        # resolve_template_value's own raise above - the filter chain
        # took the lenient ExpressionEvaluator path and FilterEngine
        # coerced the missing value into an empty hash/list, so the task
        # silently produced zero items instead of failing. Raising the
        # same UndefinedVariableError here hands it to
        # resolve_loop_items_or_raise, so the round174 skip-vs-fail-by-
        # when: matrix applies unchanged.
        if undefined_name = Krikri.undefined_filter_chain_source(bare, vars_context)
          raise UndefinedVariableError.new(Krikri.strict_undefined_message(undefined_name, vars_context))
        end

        result = expression_evaluator_for(vars_context).evaluate(bare)

        # A whole-source template whose expression ultimately renders to the
        # "undefined" sentinel is strictly fatal for loop:/with_items: (the
        # round174 matrix), and the message follows the same dict-miss
        # refinement as everywhere else (live-verified against 2.19.4: a
        # single-element array-wrapped source `loop: ["{{ d['missing'] }}"]`
        # fails with "object of type 'dict' has no attribute 'missing'", body
        # referencing item or not - 2.19 templates the whole loop list
        # up-front). Without this, the array-wrapped fallback below turned
        # the sentinel into ONE loop item equal to the literal string
        # "undefined" and ran the task with it.
        if result == "undefined"
          raise UndefinedVariableError.new(Krikri.strict_undefined_message(bare, vars_context))
        end

        if kind == "with_dict"
          # A with_dict: filter chain (dev-sec os_hardening's sysctl
          # tasks: `sysctl_config | combine(...) | combine(...)`) renders
          # to JSON object text via VariableLookup#format_value, not an
          # array - parse_list_result's as_a? would reject it outright
          # (a plain filter-chain gap here used to make the whole loop
          # resolve to nil, running the task once with `item` undefined).
          hash_result = (JSON.parse(result).as_h? rescue nil)
          return hash_result ? LoopResolver.with_dict(hash_result.transform_keys(&.to_s)) : nil
        end

        parsed = parse_list_result(result, vars_context)
        return parsed unless parsed.nil?
        # A filtered single-element array source (`with_items: ["{{ x |
        # dirname }}"]`, Oefenweb.ssh_keys, round 196) evaluates to a
        # SCALAR - parse_list_result only recognizes list shapes, so it
        # returned nil here and the function bailed with no loop items at
        # all: the task ran once with `item` unbound ("'item' is
        # undefined") where real ansible flattens the one-element array
        # one level and iterates ONCE with the scalar as `item`. Same
        # array-wrapped fallback the direct-resolution path below applies.
        return [JSON::Any.new(result)] if task.loop_template_array_wrapped?
        return nil
      end

      case kind
      when "with_items"
        # with_items: has its OWN, distinct legacy scalar-wrapping
        # behavior - real Ansible ALWAYS wraps a non-list resolution
        # into a single-item iteration, whether the source was written
        # array-wrapped (`with_items: ["{{ var }}"]`) or as a DIRECT
        # scalar template (`with_items: "{{ var }}"`, no square
        # brackets at all) - verified live against ansible-core
        # 2.19.12: `with_items: "{{ myscalar }}"` (myscalar: "ruby")
        # succeeds with exactly one iteration, `item=ruby`, no error.
        # Found via diodonfrost.amazon_codedeploy's own
        # `with_items: "{{ package_requirements }}"` (package_
        # requirements itself a `{%- if -%}...{%- endif -%}` block-tag
        # expression resolving to a plain scalar), which used to hit
        # this codebase's own `loop:`-only strict-fail branch below
        # instead ("The `loop` value must resolve to a 'list', not
        # 'str'.") - previously combined into one `when "loop",
        # "with_items"` case that (incorrectly, per this fresh live
        # check) assumed both directives shared the same strict-fail
        # rule for a non-array-wrapped scalar source.
        value.as_a? || [value]
      when "loop"
        # A single-element array holding one bare `{{ var }}` span
        # (`loop: ["{{ scalar_var }}"]`) is what routed this whole task
        # here in the first place (see find_loop_template's own
        # "flatten one level" comment) - but that parse-time heuristic
        # can't know whether `var` will turn out to be a list or a
        # scalar; only this runtime resolution can. `value.as_a?` alone
        # returns nil for a scalar, which fell through every other
        # resolver too and left the task with NO loop items at all -
        # not skipped, not looped, just run once with `item` whatever
        # (usually nothing) happened to already be in scope, silently
        # "undefined" instead of the real value. Verified against real
        # ansible-playbook directly: `loop:` treats a resolved-to-scalar
        # single-element ARRAY-WRAPPED source as exactly one iteration
        # with that scalar as `item`.
        #
        # That flatten-to-one-item leniency is only real for the
        # array-wrapped source form above - task.loop_template_array_
        # wrapped is false for the DIRECT scalar form (`loop: "{{ var
        # }}"`, no square brackets in the YAML at all), and there real
        # Ansible hard-fails a non-list resolution instead: round174
        # differential matrix scenarios 11a (`null`) / 11c (a scalar
        # string), live-verified against ansible-core 2.19.12 -
        # `The \`loop\` value must resolve to a 'list', not 'NoneType'.`
        # / `...not 'str'.`. Reuses UndefinedVariableError (not a new
        # exception type) purely so it flows through the exact same
        # resolve_loop_items_or_raise -> WhenEvaluationError rescue
        # plumbing every other loop-source failure already does - it
        # isn't really an "undefined variable" here, just a convenient
        # existing raise-and-get-rescued channel.
        if list = value.as_a?
          list
        elsif task.loop_template_array_wrapped?
          [value]
        else
          raise UndefinedVariableError.new(
            "The `loop` value must resolve to a 'list', not '#{python_type_name(value)}'.")
        end
      when "with_dict"
        hash = value.as_h?
        if hash.nil? && (arr = value.as_a?) && arr.empty?
          # Real Ansible's `with_dict:` ultimately does a Python
          # `dict(candidate)` conversion - `dict([])` succeeds (yields
          # `{}`, zero loop items, task reported "skipping"), even
          # though `dict([1, 2, 3])` (a genuinely non-empty non-mapping
          # list) would raise. A role default of `rsyslog_foo: []`
          # meant to be overridden with a real dict (buluma.rsyslog's
          # own `rsyslog_rsyslog_d_files: []`) is a common shape for
          # this - previously `value.as_h?` failing on an Array
          # returned nil for the WHOLE loop regardless of size, and
          # (per resolve_loop_template's own comment above) a nil loop
          # resolution runs the task ONCE with `item` undefined instead
          # of skipping it, so `item.key`/`item.value` raised
          # "undefined" instead of the task being skipped like real
          # Ansible.
          hash = {} of String => JSON::Any
        end
        return nil unless hash
        LoopResolver.with_dict(hash.transform_keys(&.to_s))
      when "with_nested"
        list = value.as_a?
        return nil unless list
        lists = list.map { |entry| entry.as_a? || [entry] }
        LoopResolver.with_nested(lists)
      when "with_indexed_items"
        list = value.as_a?
        return nil unless list
        LoopResolver.with_indexed_items(list)
      end
    end

    # A shared ExpressionEvaluator for a given vars context (used to resolve
    # a loop template that carries a filter chain).
    private def resolve_loop_subelements(task : Task, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      key = task.loop_subelements_key
      list_template = task.loop_subelements_list
      return nil unless key && list_template

      value = resolve_template_value(list_template, vars_context)

      # resolve_template_value only understands a bare/dotted variable
      # reference - a filter chain (`with_subelements: - "{{
      # authorized_key_list_all | selectattr('authorized_keys',
      # 'defined') | list }}"`, GROG.authorized-key's own idiom, and
      # any other selectattr/map/etc-filtered with_subelements: source)
      # doesn't match its regex at all and returned nil immediately -
      # not because the list was empty, but because it was never
      # evaluated. That nil then fell all the way out of the `||` loop-
      # resolver chain (nothing else recognizes with_subelements:
      # either), so the task wasn't treated as a loop at all and ran
      # ONCE with `item` unbound ("'item' is undefined") instead of
      # correctly iterating (possibly zero times, correctly `skipped:`)
      # over the real filtered list. Same class of gap
      # resolve_loop_template already closed for plain loop:/with_items:
      # filter chains - mirrored here via the same
      # expression_evaluator_for/parse_list_result path.
      unless value
        bare = list_template.strip
        if bare.starts_with?("{{") && bare.ends_with?("}}")
          bare = bare[2..-3].strip
        end
        result = expression_evaluator_for(vars_context).evaluate(bare)
        parsed = parse_list_result(result, vars_context)
        return nil if parsed.nil?
        return LoopResolver.with_subelements(parsed, key)
      end

      list = value.as_a? || [] of JSON::Any

      LoopResolver.with_subelements(list, key)
    end

    # with_community.general.flattened: resolve each raw source string
    # (normally `{{ some_list_var }}`) against the variable context, collect
    # the resulting lists, and flatten them into one loop-item list in
    # source order. A source that resolves to a non-list (e.g. an undefined
    # var) yields no items, matching the collection's tolerance for optional
    # source lists. Returns the flattened items, or nil when the task has no
    # flattened source at all.
    private def resolve_loop_flattened(task : Task, vars_context : Hash(String, JSON::Any), host_name : String = "localhost") : Array(JSON::Any)?
      sources = task.loop_flattened
      return nil unless sources

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
      result = [] of JSON::Any
      sources.each do |raw|
        value = resolve_template_value(raw, vars_context)

        # A complex template - `"{{ sys_accs_cond | default([]) |
        # difference(os_ignore_users) | list }}"` (dev-sec os_hardening's
        # own "change system accounts" task) - isn't a plain variable
        # reference, so #resolve_template_value returns nil.
        # #resolve_template_value only understands a bare `{{ var }}`/
        # `{{ var.dotted }}` shape; mirror #resolve_loop_template's own
        # ExpressionEvaluator fallback for anything `{{ }}`-wrapped but
        # more complex than that, before ever falling through to
        # "treat the whole source as one literal string item" below -
        # otherwise the filter chain rendered to ONE JSON-array-shaped
        # STRING ("[\"daemon\",\"bin\",...]") pushed as a single item,
        # instead of being evaluated and flattened into real per-item
        # loop iterations (`user: name={{ item }}` then tried to
        # useradd a literal string containing commas and brackets as
        # one username).
        stripped = raw.strip
        if !value && stripped.starts_with?("{{") && stripped.ends_with?("}}")
          bare = stripped[2..-3].strip
          rendered = expression_evaluator_for(vars_context).evaluate(bare)
          # Real bug found benchmarking devsec.hardening.mysql_hardening
          # (round 24 role 2): the source `{{ mysql_users_wo_passwords
          # .query_result }}` (no `| default(...)` filter - this source's
          # `when:` clause skipped its task on modern MariaDB so the
          # register was never set) renders through the bare-variable
          # path to the literal string `"undefined"`. parse_list_result
          # correctly returns nil on "undefined" (it isn't valid JSON),
          # but then the code falls through to the literal-source branch
          # below and pushes the substituted raw template as ONE loop
          # item, producing a single `item=undefined` iteration that
          # then crashes downstream as `DROP USER undefined@%`. Real
          # Ansible's with_community.general.flattened correctly yields
          # zero items for a missing-var source (skipping the whole
          # task when all sources are empty). The "undefined" sentinel
          # is the project's own (well-established) convention for
          # "no value", and the same with_community.general.flattened
          # code path already does the analogous skip for the `{{ var |
          # default([]) }}` shape - this just makes the no-filter
          # bare-`{{ var }}` shape match the same skip behavior. The
          # check is `rendered.strip not in no-value sentinels` rather
          # than a more general "parse as JSON" because the whole
          # point is that the strings "undefined", "", "[]", and "{}"
          # are the project's own no-value sentinels (a bare
          # `{{ missing_var }}` reference renders to "undefined"; a
          # `{{ missing_var | default([]) }}` filter chain where the
          # whole `missing_var` is undefined renders to ""; a
          # `{{ existing_var.list | default([]) }}` chain where the
          # var IS set but the underlying value is itself an empty
          # list renders to "[]"; same for "{}" on an empty dict). A
          # filter chain that legitimately produced a non-empty list,
          # a non-empty dict, a string, or any other value would never
          # render to any of these four strings through this
          # evaluator.
          if rendered.strip != "undefined" && rendered.strip != "" && rendered.strip != "[]" && rendered.strip != "{}" && (parsed = parse_list_result(rendered, vars_context))
            value = JSON::Any.new(parsed)
          end
        end

        if value
          if value.raw.is_a?(Array)
            value.as_a.each do |item|
              # Flatten one level of board nesting, matching the
              # collection's flattened semantics for a list-of-lists source.
              if item.raw.is_a?(Array)
                item.as_a.each { |leaf| result << leaf }
              else
                result << item
              end
            end
          else
            result << value
          end
        else
          # A literal source (not a bare `{{ var }}` reference or a
          # `{{ }}`-wrapped filter-chain expression at all) - dev-sec
          # os_hardening's own with_flattened sources are mostly plain
          # literal paths ('/usr/local/sbin', '/usr/local/bin', ...)
          # mixed with exactly one templated (often-empty-by-default)
          # list source. Previously `next unless value` dropped every
          # literal source outright, so a loop mixing literal paths with
          # one templated source produced ZERO items instead of the
          # literal paths themselves - found via os-hardening's own
          # "find files with write-permissions for group" task (6
          # literal paths + `{{ os_env_extra_user_paths }}`, default
          # `[]`), which skipped outright instead of running find
          # against any of the 6 real directories. Still substituted
          # (not just pushed raw) in case a literal source has `{{ }}`
          # embedded alongside other text, not only as the whole string.
          #
          # A `{{ }}`-wrapped source whose only variable is missing
          # also lands here (the complex-template fallback at the
          # top of this loop ALSO returns nil for it now - see the
          # `rendered.strip != "undefined"` guard there). The same
          # skip-for-missing-var policy applies: a substituted result
          # that is one of the project's own no-value sentinels - the
          # literal string "undefined" (a bare `{{ missing_var }}`
          # reference), the empty string "" (a `{{ missing_var |
          # default([]) }}` filter chain where the filter's
          # undefined?-check on a fully-missing variable doesn't
          # trigger the default - verified by test_eval9.cr: `q.r |
          # default([])` with `q` missing returns ""), OR the string
          # "[]" (a `{{ existing_var.query_result | default([]) }}`
          # chain where the var IS set but the underlying value is
          # itself an empty list, so the finalization renders it as
          # the JSON-string "[]") - is "no value", not "one item with
          # that value". Real Ansible's with_community.general.
          # flattened yields zero items for any of these no-value
          # sentinels. Pushing the bogus value would cascade into
          # downstream `{{ item.X }}` rendering as "undefined" again
          # (or as nothing for ""), which then crashes for any tool
          # that tries to use the bogus value (devsec.mysql_hardening's
          # DROP USER undefined@% is the live example that surfaced
          # this). A legitimate literal source that wants the bare
          # string "[]" pushed as one item is implausible - roles
          # iterate lists, not the string representation of a list.
          substituted = substitutor.substitute(raw).strip
          case substituted
          when "undefined", "", "[]", "{}"
            # no items from this source - all four are "the engine
            # has no value to give this loop" sentinels
          else
            result << JSON::Any.new(substituted)
          end
        end
      end
      result
    end

    # Resolve a bare "{{ expr }}" template (optionally with leading/trailing
    # whitespace) to the underlying JSON value from the variable context,
    # preserving arrays/hashes rather than flattening to a string the way
    # VarSubstitutor#substitute does. Supports simple and dotted variable
    # references (e.g. "some_var" or "some_dict.key"); anything more complex
    # (filters, expressions) isn't a variable reference and returns nil.
    #
    # The only 3 callers of this method are all loop-source resolvers
    # (resolve_loop_template, resolve_loop_subelements, resolve_loop_
    # flattened - verified by grep before making this raise unconditional).
    # A bare/dotted reference (REGEX_BARE_VAR_REF's exact shape) that
    # resolves to nothing now RAISES rather than silently returning nil -
    # round174 differential matrix: real Ansible fails a genuinely
    # undefined loop:/with_items:/with_dict:/with_community.general.
    # flattened: source with "'the_var' is undefined" at loop-resolution
    # time, before the task ever runs (not "runs once with an unbound
    # item"). A filter/default()/lookup() chain never reaches this method
    # at all (the leading regex requires the WHOLE `{{ }}` span to be a
    # plain reference) - that's resolve_loop_template/resolve_loop_
    # flattened's own separate ExpressionEvaluator fallback branch, left
    # untouched, so `{{ undefined_var | default([]) }}` stays lenient.
    # Every caller now needs (and, per this commit, has) a rescue around
    # its own loop-resolution call - see resolve_loop_items_or_raise.
    private def flatten_with_items_one_level(items : Array(JSON::Any)) : Array(JSON::Any)
      items.flat_map { |item| item.as_a? || [item] }
    end

    private def resolve_loop_items_or_raise(task : Task, host : Host, vars_context : Hash(String, JSON::Any), & : -> Array(JSON::Any)?) : Array(JSON::Any)?
      yield
    rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
      # Same degrade-to-failed-task treatment as the UndefinedVariableError
      # case below - a loop: source referencing a filter this engine
      # doesn't implement (oasis_roles.system_repositories's own
      # role-local filter_plugins/exclude.py, which krikri can't execute
      # at all - a real, understood scope limit) previously propagated
      # as an unrescued exception all the way out of #run and crashed the
      # ENTIRE krikri-playbook process instead of just failing this one
      # task, losing every other host/task the run would otherwise have
      # completed. Real Ansible's own AnsibleFilterError for an unknown
      # filter fails only the task.
      raise WhenEvaluationError.new(ex.message)
    rescue ex : UndefinedVariableError
      if when_condition = task.when_condition
        # Lenient evaluation on purpose: `item.backup is defined` with
        # `item` unbound must read as false (skip), not raise. A when:
        # that is itself strictly-undefined still fails downstream via
        # when_passes?'s own raise_undefined: path, which is where real
        # Ansible reports it too.
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        skippable = begin
          !ConditionalEvaluator.evaluate(substitutor.substitute(when_condition), vars_context)
        rescue
          false
        end
        return nil if skippable
      end

      raise WhenEvaluationError.new(ex.message)
    end

    # Real Ansible resolves a task's module/action plugin before it ever
    # looks at what the loop would iterate over - an unresolvable module
    # is a fatal error regardless of whether the loop it's attached to
    # turns out to have zero items. Shared by when_passes? (the per-item/
    # non-looped path, called at least once whenever there's ≥1 loop item
    # to evaluate a when: against) and execute_looped_task's empty-loop
    # case (loop_items.empty?, where when_passes? is never reached at all
    # - nothing to iterate means nothing to call it on - so this module
    # check would otherwise silently never run and the task would just
    # print "skipping:" instead of the fatal rc=4 real Ansible gives).
    # Found via robertdebock.postgres's "Create postgres database" task:
    # community.postgresql.postgresql_db, looped over the (empty-by-
    # default) postgres_databases, with the community.postgresql
    # collection not installed.
    # Renders every loop item strictly (deep_render_item's default), with
    # real Ansible's when:-before-loop ordering on failure: a task-level
    # `when:` that evaluates False leniently (including the `when: item is
    # defined` idiom with `item` unbound) means the task is SKIPPED before
    # any item would ever have been templated (live-verified against
    # 2.19.4: `when: false` + undefined loop item → skipping, never an
    # error; `when: true` + undefined item → task failed). Returns nil for
    # that skip case; raises WhenEvaluationError for the genuine failure
    # (the execute_looped_task call site turns it into one clean failed
    # task, same as a loop-source resolution failure).
    private def render_loop_items_strict_or_raise(
      task : Task,
      loop_items : Array(JSON::Any),
      vars_context : Hash(String, JSON::Any),
      host_name : String,
    ) : Array(JSON::Any)?
      begin
        loop_items.map { |item| deep_render_item(item, vars_context, host_name) }
      rescue ex : UndefinedVariableError
        if when_condition = task.when_condition
          substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
          skippable = begin
            !ConditionalEvaluator.evaluate(substitutor.substitute(when_condition), vars_context)
          rescue
            false
          end
          return nil if skippable
        end
        raise WhenEvaluationError.new(ex.message)
      end
    end

    private def execute_looped_task(
      task : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any),
      exec_host : Host = host,
    )
      # See register_reachable_unavailable_module's own comment: an empty
      # loop means no item ever reaches when_passes?, so the module-
      # resolution check that call normally carries has to happen here
      # instead, once, against the task's own when: (there's no item to
      # bind yet either way).
      register_reachable_unavailable_module(task, base_vars_context, host) if loop_items.empty?

      # Render each item *before* it's ever bound to "item" or checked
      # against when: - a literal loop: entry can itself be a template
      # string (dev-sec mysql_hardening's own "Ensure permissions on
      # mysql-datadir are correct": `loop: ["{{ mysql_settings.settings.
      # datadir }}", '{{ mysql_datadir | default("") }}']`, gated by
      # `when: item != ""`). Previously bound the raw unrendered text
      # (e.g. the literal string '{{ mysql_datadir | default("") }}') as
      # "item" - a later re-templating pass happening to fix up the
      # *param* substitution masked this for a task's own params, but
      # when:'s own item comparison saw the raw text directly: a
      # non-empty string regardless of what it would have rendered to,
      # so `item != ""` was always true and a should-have-been-skipped
      # item ran for real, on a bogus literal path.
      rendered_items = render_loop_items_strict_or_raise(task, loop_items, base_vars_context, host.name)
      if rendered_items.nil?
        # Strict item templating failed but the task's own when: evaluates
        # False without `item` bound - real Ansible evaluates the when:
        # before ever templating the loop list, so this is a plain skip
        # (live-verified: `when: false` + an undefined loop item prints
        # "skipping:" and counts skipped=1, never an error).
        @results[host.name]["skipped"] += 1
        puts "skipping: [#{host.connection_host}]".colorize(:cyan)
        register_skip_result(task, host)
        return
      end
      rendered_items = flatten_with_items_one_level(rendered_items) if task.loop_items_needs_flatten?

      # Per-item fact target, for delegate_to:/delegate_facts: - only ever
      # diverges from `host` in the non-batched branch below (batching is
      # excluded outright for a delegate_to: task by loop_batch_eligible?).
      fact_hosts = Array(Host).new(rendered_items.size, host)

      item_results = if loop_batch_eligible?(task, host, exec_host, base_vars_context)
                       execute_looped_task_batched(task, host, base_vars_context, rendered_items)
                     else
                       # A running (not re-dup'd-from-base) vars_context
                       # carries each iteration's ansible_facts forward
                       # into the next - real Ansible does the same for
                       # set_fact:, and dev-sec os_hardening's own account-
                       # list building depends on it: `set_fact:
                       # system_users: "{{ system_users | default([]) +
                       # [item] }}"` inside a loop needs iteration N to see
                       # iteration N-1's accumulated list, not the loop's
                       # starting value every time.
                       running_vars_context = base_vars_context.dup
                       loop_var = task.loop_var
                       index_var = task.index_var
                       rendered_items.map_with_index do |item, idx|
                         vars_context = running_vars_context.dup
                         vars_context["item"] = item
                         vars_context[loop_var] = item if loop_var
                         vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
                         vars_context["ansible_loop"] = ansible_loop_vars(loop_items, idx.to_i) if task.loop_extended?

                         # A task-level vars: that references `item`
                         # (linux-system-roles/kernel_settings' own
                         # `vars: {new_item: "{{ {item.name: new_value}
                         # }}"}` on a looped set_fact:) was only ever
                         # rendered *once*, by build_vars_context, before
                         # this loop even started - when `item` was still
                         # unbound. Every iteration then reused that same
                         # first (wrong) rendered value instead of
                         # recomputing it against its own item. Restoring
                         # task.vars' original unrendered text before each
                         # iteration's render_task_vars call fixes this;
                         # cheap enough even for a task whose vars: don't
                         # reference item at all (identical result either
                         # way), so no need to detect which case this is.
                         #
                         # `task.vars` also carries an inherited "item"/
                         # loop_var binding when this task lives inside an
                         # include_tasks: file whose OWN include statement
                         # was itself looped (execute_include_tasks
                         # propagates the outer iteration's item into
                         # every included task's `vars` so a non-looped
                         # included task can still see it - see the
                         # comment there). When the included task ALSO has
                         # its own `loop:`, blindly re-applying every
                         # `task.vars` key here clobbered the fresh,
                         # correct inner-loop "item"/loop_var binding set
                         # two lines above with that stale OUTER value,
                         # right before this same key would otherwise have
                         # been used to render/execute the task - `{{ item
                         # }}` (or a custom loop_var) inside the included
                         # task's own loop resolved to the outer include's
                         # item on every inner iteration instead of the
                         # inner loop's real one. Found via robertdebock.
                         # diskspace's own `mount.yml`, `include_tasks:`d
                         # in a loop with `loop_var: mount`, whose own
                         # `mount | Check space available` task loops
                         # `ansible_facts['mounts']` under the default
                         # `item` - the disk-space assertion never once
                         # matched a real mount entry, so the whole role's
                         # actual purpose (failing on low disk space)
                         # silently never fired. The loop's own binding
                         # must always win over an inherited one for the
                         # same key.
                         task.vars.each do |key, raw_value|
                           next if key == "item" || key == loop_var || key == index_var
                           vars_context[key] = raw_value
                         end
                         render_task_vars(task, vars_context, host.name)

                         # delegate_to: templated against the loop variable
                         # itself (geerlingguy.kubernetes' own "Set the
                         # kubeadm join command globally.": `delegate_to:
                         # "{{ item }}"`, `with_items: "{{ groups['all'] }}"`)
                         # must be re-resolved per iteration, against THIS
                         # item's own vars_context - the outer `exec_host`
                         # passed into this method was resolved once, before
                         # the loop ever bound "item", so a templated
                         # delegate_to always saw it as undefined and
                         # resolved to a host literally named "undefined"
                         # (crashing the SSH connection outright, not just
                         # producing a wrong result).
                         item_exec_host = task.delegate_to ? resolve_delegate_host(task, host, vars_context) : exec_host
                         fact_hosts[idx] = item_exec_host if task.delegate_facts? && task.delegate_to

                         item_label = item_label_for(task, item, vars_context, host)
                         result = if (until_condition = task.until_condition) && !resolve_task_check_mode(task, vars_context)
                           # Real Ansible retries each loop item
                           # independently under until:/retries: - the
                           # loop_items branch used to return before the
                           # until branch in execute_task, silently
                           # dropping retries for looped tasks.
                           run_until_retries(task, host, vars_context, until_condition, item_exec_host, defer_loop_stats: true, item_label: item_label)
                         else
                           execute_task_once(task, host, vars_context, item_label: item_label, exec_host: item_exec_host, defer_loop_stats: true)
                         end
                         if result && (facts = result["ansible_facts"]?) && (facts_hash = facts.as_h?)
                           facts_hash.each { |key, value| running_vars_context[key] = value }
                         end
                         result
                       end
                     end

      finish_looped_task(task, host, rendered_items, item_results, fact_hosts, base_vars_context)
    end

    # Whether execute_looped_task can send every surviving item through
    # one shared SSH round trip instead of one per item. Loop iterations
    # of a single task can never reference each other's *remote* results
    # (Ansible has no such semantic for a command's stdout/rc), unlike
    # mixed-task batching's references_register? check - but set_fact:
    # is purely controller-side and each iteration's result (its
    # ansible_facts) genuinely does need to carry into the next (see the
    # running_vars_context comment above) - a single upfront batch script
    # can't do that, so it's excluded here rather than silently losing
    # the accumulation.
    #
    # changed_when:/failed_when: do NOT need excluding here (they used
    # to be, copied over from task_batcher.cr's retroactive_verdict?
    # category for *mixed*-task batching, where the real concern is a
    # later task's changed_when referencing an earlier task's *not-yet-
    # applied* register: result) - execute_looped_task_batched already
    # calls apply_changed_failed_when per item, after the batch script
    # returns, using that item's own result. There's no cross-item
    # reference to get wrong the way mixed-task batching has. Excluding
    # it here bought nothing and cost a lot: konstruktoid-hardening's
    # "Find possible suid binaries" loops `command -v` over 411 items
    # with `changed_when: false, failed_when: false` (an extremely
    # common idiom for "this is read-only, never report changed") -
    # falling back to one real SSH round trip *per item* turned a task
    # that should take a couple of seconds into many minutes, consistent
    # with two separate real-host runs both dying of a `timeout 2400`
    # wrapper at the exact same point (identical line counts) rather
    # than any actual host/network failure.
    private def loop_batch_eligible?(task : Task, host : Host, exec_host : Host, vars_context : Hash(String, JSON::Any)) : Bool
      return false unless @batching_enabled
      return false unless exec_host == host
      return false if task.module_name.ends_with?("set_fact")
      return false if task.delegate_to
      # A templated action:/local_action: resolves per item inside
      # execute_task_once; the batched-loop path pre-builds every
      # iteration's step from the parse-time params, which don't exist
      # for it yet.
      return false if task.templated_action
      return false if task.until_condition
      return false if PluginManager.local_connection?(exec_host, vars_context)
      true
    end

    # Runs *loop_items* through one shared SSH round trip. When: is
    # evaluated per item up front (safe: an item's when: depends only on
    # `item` + the base context, both known before any remote call) and
    # skips are recorded exactly as the one-at-a-time path does via
    # when_passes? itself. Returns one result per item (nil = skipped or
    # never reached), consumed afterward by finish_looped_task exactly
    # like the one-at-a-time path's own results.
    private def execute_looped_task_batched(
      task : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any),
    ) : Array(JSON::Any?)
      item_results = Array(JSON::Any?).new(loop_items.size, nil)
      item_contexts = Hash(Int32, Hash(String, JSON::Any)).new
      steps = [] of BatchScript::Step
      step_indices = [] of Int32
      loop_var = task.loop_var
      index_var = task.index_var

      loop_items.each_with_index do |item, idx|
        vars_context = base_vars_context.dup
        vars_context["item"] = item
        vars_context[loop_var] = item if loop_var
        vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var
        vars_context["ansible_loop"] = ansible_loop_vars(loop_items, idx) if task.loop_extended?
        item_contexts[idx] = vars_context

        # Per item, not per call: each iteration builds its own context
        # (base.dup + "item"), but when: and the step preparation both
        # read that same one.
        item_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

        begin
          next unless when_passes?(task, vars_context, host, item_label: item_label_for(task, item, vars_context, host), shared: item_substitutor, defer_stats: true)
        rescue ex : WhenEvaluationError
          # Same rationale as execute_task_once's own identical rescue -
          # a real failed result here (not a silent skip) lets
          # finish_looped_task's aggregation correctly count this as
          # failed=1, not skipped=1.
          item_results[idx] = when_error_result(ex)
          next
        end

        case outcome = prepare_batch_step(task, host, vars_context, shared: item_substitutor)
        when JSON::Any
          item_results[idx] = outcome
        when BatchScript::Step
          # ignore_errors: is per-*task*, but forced true here regardless
          # of the task's own value: today's loop always attempts every
          # item even after an earlier one fails, and the script's fail-
          # fast (built for the mixed-task batch case, where a failure
          # really should stop the remaining tasks) would otherwise halt
          # the script on the first failing item without ignore_errors:,
          # silently changing that continue-after-failure behavior as a
          # side effect of batching it.
          steps << BatchScript::Step.new(outcome.plugin_target, outcome.config_json, true,
            outcome.module_name, outcome.become_user)
          step_indices << idx
        end
      end

      return item_results if steps.empty?

      connection_host = PluginManager.get_connection_host(host, item_contexts[step_indices.first])
      step_results = run_batch_steps(host, connection_host, steps)

      steps.each_index do |i|
        next unless interpreted = step_results[i]?

        idx = step_indices[i]
        vars_context = item_contexts[idx]
        item_results[idx] = apply_changed_failed_when(task, interpreted, vars_context, host)
      end

      item_results
    end

    # Shared aggregation for a completed loop's per-item results (used by
    # both the batched and one-at-a-time paths) so register:/notify:/
    # stats/halt bookkeeping stays byte-identical regardless of which
    # transport produced the results.
    private def finish_looped_task(task : Task, host : Host, loop_items : Array(JSON::Any), item_results : Array(JSON::Any?), fact_hosts : Array(Host)? = nil, base_vars_context : Hash(String, JSON::Any)? = nil) : Nil
      results = [] of JSON::Any
      any_changed = false
      any_failed = false

      executed_count = 0
      # The base context (everything except the per-item bindings) is
      # host- and task-level and cannot change between loop items - the
      # tiered merge + hostvars/groups + magic vars this builds is the
      # single most expensive call in the engine, so build it ONCE here
      # and shallow-copy per item (key assignment on the copy), not once
      # per item. Tradeoff, documented: a looped set_fact:'s mid-loop
      # fact changes are not reflected in a LATER item's loop_control.
      # label - display-only, and consistent with this file's established
      # "first host" precedent for banner rendering.
      # Reuse the caller's own context (built just before the loop ran)
      # instead of rebuilding it here, and skip the per-item copies
      # entirely when the task has no loop_control.label - item_label_for
      # falls straight through to item_display unless a label is
      # configured, so the context was pure waste in the common case.
      # Tradeoff, documented: a looped set_fact:'s mid-loop fact changes
      # are not reflected in a LATER item's loop_control.label -
      # display-only, and consistent with this file's established "first
      # host" precedent for banner rendering.
      label_base_context = task.loop_label ? (base_vars_context || build_vars_context(task, host)) : nil
      loop_items.each_with_index do |item, idx|
        result = item_results[idx]
        next unless result

        executed_count += 1
        merge_ansible_facts(fact_hosts.try(&.[idx]) || host, result, task.module_name.ends_with?("set_fact"))

        changed = result["changed"]?.try(&.as_bool) || false
        failed = result["failed"]?.try(&.as_bool) || false
        any_changed ||= changed
        any_failed ||= failed

        # loop_control.label renders against this item, so it needs a
        # context carrying it - this method is handed only the results.
        # No label configured -> no context needed at all.
        item_label = if base = label_base_context
                       label_context = base.dup
                       label_context["item"] = item
                       if loop_var = task.loop_var
                         label_context[loop_var] = item
                       end
                       label_context["ansible_loop"] = ansible_loop_vars(loop_items, idx) if task.loop_extended?
                       item_label_for(task, item, label_context, host)
                     else
                       item_display(item)
                     end

        ResultDisplay.display_result(host, result, @diff_mode, item_label: item_label, ignore_errors: task.ignore_errors?, no_log: task.no_log?)

        result_hash = result.as_h.dup
        result_hash["item"] = item
        # loop_control: { loop_var: some_name } exposes the item under
        # that CUSTOM name too, in addition to "item" (real Ansible's
        # own behavior, matching how the live execution context already
        # binds both - see label_context above) - previously only ever
        # set here regardless of loop_control, so a later `map(attribute:
        # <custom_name>)`/`selectattr(<custom_name>, ...)` over
        # registered.results always saw that key as missing (null).
        # Found benchmarking githubixx.containerd's own "Set
        # modprobe_location" (`loop_control: { loop_var: path }` +
        # `modprobe_locations.results | ... | map(attribute='path')`).
        if loop_var = task.loop_var
          result_hash[loop_var] = item
        end
        results << JSON::Any.new(result_hash)
      end

      # Aggregate the whole loop into ONE recap entry, matching real
      # Ansible: a looped task counts once, not once per item.
      #   - 0 items executed (all skipped, or an empty loop) -> skipped=1
      #   - >=1 item executed -> ok=1 (plus changed=1 if any item changed),
      #     or failed=1 if any item failed (honoring ignore_errors).
      # The per-item `skipping:`/`changed:`/`ok:` lines above are display
      # only; Ansible prints those but sums the task once in the recap.
      if executed_count == 0
        # A genuinely empty loop source (0 items total, not "every item's
        # own when: was false" - those already printed their own
        # per-item `skipping: [host] => (item=x)` lines above) never
        # printed anything at all otherwise - real Ansible still emits
        # one bare `skipping: [host]` line for it (dev-sec os_hardening's
        # with_subelements:/with_community.general.flattened: tasks hit
        # this whenever nothing matched, e.g. no world-writable files
        # found to fix).
        if loop_items.empty?
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "skipping: [#{connection_host}]".colorize(:cyan)
        end
        @results[host.name]["skipped"] += 1
      else
        aggregate_result = JSON.parse({
          "changed" => JSON::Any.new(any_changed),
          "failed"  => JSON::Any.new(any_failed),
        }.to_json)
        ResultDisplay.update_stats(@results[host.name], aggregate_result, task.ignore_errors?)
      end

      if any_changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if register_name = task.register
        unless register_name.empty?
          aggregate = {
            "changed" => JSON::Any.new(any_changed),
            "failed"  => JSON::Any.new(any_failed),
            "results" => JSON::Any.new(results),
          }
          @registered_vars[host.name][register_name] = JSON::Any.new(aggregate)
          @hv_generation += 1
        end
      end

      halt_if_failed(task, host, any_failed)
    end

    # Render a loop item for display purposes (Ansible shows `(item=...)`).
    # loop_control.extended - real Ansible's `ansible_loop` dict for the
    # current iteration. Keys and semantics verified against ansible-core
    # 2.19.4 over a 3-item loop: index is 1-based, revindex counts down
    # from length, and nextitem/previtem are ABSENT (not null) at the
    # ends, so `| default(...)` is what a playbook uses there.
    private def ansible_loop_vars(items : Array(JSON::Any), idx : Int32) : JSON::Any
      entry = Hash(String, JSON::Any).new
      entry["index"] = JSON::Any.new((idx + 1).to_i64)
      entry["index0"] = JSON::Any.new(idx.to_i64)
      entry["revindex"] = JSON::Any.new((items.size - idx).to_i64)
      entry["revindex0"] = JSON::Any.new((items.size - idx - 1).to_i64)
      entry["first"] = JSON::Any.new(idx == 0)
      entry["last"] = JSON::Any.new(idx == items.size - 1)
      entry["length"] = JSON::Any.new(items.size.to_i64)
      entry["allitems"] = JSON::Any.new(items)
      entry["nextitem"] = items[idx + 1] if idx + 1 < items.size
      entry["previtem"] = items[idx - 1] if idx > 0
      JSON::Any.new(entry)
    end

    # loop_control.label - what the per-item line shows instead of the
    # raw item. Rendered against that item's own context, so it can name
    # a field of the item.
    # Shared `until:` retry core - drives task.retries/task.delay attempts
    # of execute_task_once until the rendered condition passes. Used both
    # by execute_task_with_retries (single task, displays its final result)
    # and, per item, by execute_looped_task's non-batched path (real
    # Ansible retries each loop item independently).
    private def run_until_retries(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      until_condition : String,
      exec_host : Host = host,
      defer_loop_stats : Bool = false,
      item_label : String? = nil,
    ) : JSON::Any?
      register_name = task.register
      attempts = task.retries.clamp(1..)
      result = nil

      attempts.times do |attempt|
        result = execute_task_once(task, host, vars_context, item_label: item_label, exec_host: exec_host, defer_loop_stats: defer_loop_stats)
        break unless result

        if register_name && !register_name.empty?
          register_result(host, register_name, result)
          vars_context[register_name] = @registered_vars[host.name][register_name]
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(until_condition)
        break if ConditionalEvaluator.evaluate(substituted_condition, vars_context)

        sleep(task.delay.seconds) if attempt < attempts - 1
      end

      result
    end

    private def execute_task_with_retries(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      until_condition : String,
      exec_host : Host = host,
    )
      result = run_until_retries(task, host, vars_context, until_condition, exec_host)

      return unless result

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if @adhoc
        ResultDisplay.display_adhoc_result(host, result)
      else
        ResultDisplay.display_result(host, result, @diff_mode, ignore_errors: task.ignore_errors?, no_log: task.no_log?)
      end
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors?)
      halt_if_failed(task, host, failed)
    end

    # Prints and counts each of *tasks* as individually skipped - used
    # when a block:'s own when: is false, since real Ansible expands a
    # block into its member tasks rather than reporting one aggregate
    # skip for the block itself. Recurses into a nested block so its own
    # members are reported individually too, matching how a nested
    # block's when: (false or not) would otherwise be evaluated.
    # AND a block's own when: onto each of its children, so a condition
    # that raised at the block level is re-evaluated (and re-raised) once
    # per child task the way real Ansible's own when: inheritance does.
    # Idempotent: the Task objects are shared across hosts in a
    # multi-host play, so a second host reaching the same failing block
    # must not wrap the condition twice.
  end
end
