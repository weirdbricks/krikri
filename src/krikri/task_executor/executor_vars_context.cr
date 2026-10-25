require "../run_options"
require "../deprecation_hint"
require "./executor"
require "krikri-jinja/krikri_jinja"
require "../jinja_host_context"
require "../needle_lookup"

module Krikri
  class TaskExecutor
    # The VarOrigin of the layer that actually supplies *name*'s value
    # for this task/host - replaying build_vars_context's exact merge
    # sequence (including the registered-var skip that lifts registered
    # results above the role-var layers) and returning the winning
    # layer's origin. nil when the winner has no known origin (runtime
    # values - registered results, facts, set_fact - and definitions no
    # source map covers): the warning block for such a context is then
    # omitted, never mislabeled.
    #
    # runtime_marker (used only by the conditional-value origin
    # decoration): the runtime layers report RuntimeVarOrigin instead of
    # nil - real's data lineage for those values labels the conditional
    # error with the when: token itself (live-verified 2.19.11), which
    # the caller resolves from the marker - and a set_fact value rides
    # its recorded @set_fact_origins entry. The name-template warning
    # callers keep the default (nil), so their behavior is untouched.
    private def var_origin_for(task : Task, host : Host, name : String, runtime_marker : Bool = false) : VarOrigin?
      winner : VarOrigin? = nil
      have = false
      set = ->(origin : VarOrigin?) do
        have = true
        winner = origin
      end

      # baseA, in its own merge order: play vars, inventory host vars,
      # registered results, then facts fill-only.
      if @play_vars.has_key?(name)
        set.call(@play_var_origins[name]?)
      end
      if host.vars.has_key?(name)
        set.call(host.var_origins[name]?)
      end
      registered = @registered_vars[host.name]
      if registered.has_key?(name)
        set.call(runtime_marker ? RuntimeVarOrigin.new : nil)
      end
      if !have && @facts[host.name].has_key?(name)
        set.call(runtime_marker ? RuntimeVarOrigin.new : nil)
      end

      # The two fill-only defaults layers: task.role_defaults applied
      # first, so it wins what it has.
      if !have && (rd = task.role_defaults) && rd.has_key?(name)
        set.call(task.role_default_origins[name]?)
      end
      if !have && @all_role_defaults.has_key?(name)
        set.call(@all_role_default_origins[name]?)
      end

      # vars_files overwrite the whole baseA but lose to the role-var and
      # task-var layers.
      cache_key = vars_files_cache_key(host)
      if (vf = load_vars_files(host)) && vf.has_key?(name)
        set.call(@vars_files_origins_cache[cache_key]?.try(&.[name]?))
      end

      # The role-var layers overwrite everything above, EXCEPT a key a
      # registered result already holds (build_vars_context skips those).
      if (rv = task.role_vars) && rv.has_key?(name) && !registered.has_key?(name)
        set.call(task.role_var_origins[name]?)
      end
      if @all_role_vars.has_key?(name) && !registered.has_key?(name)
        set.call(@all_role_var_origins[name]?)
      end

      if task.vars.has_key?(name)
        set.call(task.vars_origins[name]?)
      end

      # baseB (included_vars/facts/set_facts) and -e/--extra-vars are the
      # final words; their values are never raw templates with a
      # knowable file origin - EXCEPT an include_vars: file's values
      # (real points the Origin at the included file's own value line,
      # live-verified vs 2.19.11) and an `-e @file` value (origin: the
      # file's value position).
      if base_context_b_for(host).has_key?(name)
        # A set_fact value carries its own origin (the value token in the
        # set_fact task's source file); the other baseB members with no
        # recorded origin (failure_vars) get the runtime marker.
        set.call(@set_fact_origins[host.name]?.try(&.[name]?) || (runtime_marker ? RuntimeVarOrigin.new : nil))
      end
      if (iv = @included_vars[host.name]?) && iv.has_key?(name)
        set.call(@included_var_origins[host.name]?.try(&.[name]?))
      end
      if @extra_vars.has_key?(name)
        raw = @extra_vars[name]
        set.call(@extra_var_origins[name]? || TextVarOrigin.new("<CLI option '-e'>", raw.as_s? || raw.to_s))
      end

      have ? winner : nil
    end

    # The PLAY-LEVEL variable layers only - Ansible's
    # get_vars(play=play, task=handler) shape: NO host-scoped variables
    # at all (no host vars, registered results, facts, set_facts or
    # include_vars). Used for handler-name templating, where real
    # deliberately excludes host variables ("host-specific variables
    # are not supported in handler names", live-verified vs 2.19.11: a
    # handler name referencing an inventory host_vars value fails with
    # "'x' is undefined" even though the task-layer value resolves).
    private def play_level_vars_context(task : Task, host : Host) : Hash(String, JSON::Any)
      vars_context = {} of String => JSON::Any

      @play_vars.each { |key, value| vars_context[key] = value }

      if (rd = task.role_defaults) && !rd.empty?
        rd.each { |key, value| vars_context[key] ||= value }
      end
      @all_role_defaults.each { |key, value| vars_context[key] ||= value }

      unless @vars_files.empty?
        load_vars_files(host).each { |key, value| vars_context[key] = value }
      end

      if (rv = task.role_vars) && !rv.empty?
        rv.each { |key, value| vars_context[key] = value }
      end
      @all_role_vars.each { |key, value| vars_context[key] = value }

      task.vars.each { |key, value| vars_context[key] = value }

      @extra_vars.each { |key, value| vars_context[key] = value }

      vars_context
    end

    private def build_vars_context(task : Task, host : Host, include_legacy_ssh_aliases : Bool = true, loop_lenient_vars : Bool = false) : Hash(String, JSON::Any)
      # See the @base_context_a_cache/@base_context_b_cache ivar comments
      # above for why this is 2 caches, not 1, and exactly what real
      # precedence order each preserves. role_defaults < baseA
      # (play_vars/host.vars/registered_vars) < role_vars < task.vars <
      # baseB (included_vars/facts/host-magic) is the SAME order
      # VariableContext.build + the old included_vars/facts/magic-var
      # block always applied - only the "did we just recompute this
      # host's unchanging inputs again" cost changed, not what wins a
      # same-key collision.
      # `Hash#dup` is a bulk copy of the internal entries array - measured
      # ~3.4x faster than rebuilding the same-sized hash via an `.each`
      # insert loop (200-entry hash, 200k iterations: 599ms vs 176ms,
      # `--release`). Only usable where the destination starts EMPTY,
      # which is exactly baseA's position here - it's the first tier
      # applied, and the one tier below it (role_defaults) is small and
      # per-role, not per-host, so folding it in via `||=` after the dup
      # (rather than `[]=` before it) is cheap however it's done and
      # correctly reproduces "role_defaults only fills what baseA doesn't
      # already have" - Ansible's own actual precedence, unchanged
      # from what `VariableContext.build`'s ordering used to guarantee
      # via unconditional overwrite-in-priority-order instead.
      vars_context = base_context_a_for(host).dup

      # Connection vars only: Ansible ranks play vars ABOVE inventory
      # host vars, but baseA's merge order (an internal performance
      # layout, not a precedence claim) lets host.vars overwrite
      # play_vars keys for everything. Re-applying the play's own value
      # for the SSH connection keys makes a play-level
      # `vars: {ansible_user: ...}` / `ansible_port: ...` etc. actually
      # win over the inventory the way ansible-playbook 2.19.11 does
      # (live-verified), without touching the general play/host
      # ordering for every other key. A registered var (set_fact:) for
      # the same key still wins - Ansible's registered tier outranks
      # play vars - so it is left exactly as baseA stacked it.
      ConnectionSettings::CONNECTION_VAR_KEYS.each do |key|
        next if @registered_vars[host.name].has_key?(key)
        vars_context[key] = @play_vars[key] if @play_vars.has_key?(key)
      end

      # Synthesized here (not in the cached baseA below) so the legacy
      # spellings can be withheld from loop-source resolution - see
      # #synthesize_legacy_ssh_aliases and #loop_source_vars_context.
      synthesize_legacy_ssh_aliases(vars_context) if include_legacy_ssh_aliases
      # vars_files: sit ABOVE play vars and below role/task vars -
      # Ansible's documented order, verified live: a name set in both
      # `vars:` and a vars_file resolves to the FILE's value, and a later
      # file beats an earlier one. Merged here, straight after the tier
      # holding play_vars, so role_vars/task.vars below still win.
      unless @vars_files.empty?
        load_vars_files(host).each { |key, value| vars_context[key] = value }
      end

      # Play-wide role layers. Ansible's precedence here was
      # established against ansible-core 2.19.4 with a three-way matrix
      # (see role_scope_spec.cr, which encodes every case), and the
      # ladder it produced is, low to high:
      #
      #   all roles' defaults < this role's own defaults < play vars
      #     < all roles' vars < this role's own vars
      #
      # so: another role's DEFAULT never beats this role's own, but
      # another role's VAR beats this role's own default (verified:
      # alpha's own `x_name` default resolves to beta's `x_name` var),
      # and outside any role the LAST-loaded role wins each layer.
      # Both defaults layers are applied with `||=` (fill-only), so the
      # one applied FIRST wins - this role's own defaults go in ahead of
      # the play-wide layer, which is what makes another role's default
      # lose to this role's own (verified: with `shared_default` set by
      # both roles, alpha's tasks see alpha's value and beta's see
      # beta's, while a task outside any role sees the LAST role's).
      if defaults = task.role_defaults
        defaults.each { |key, value| vars_context[key] ||= value }
      end

      @all_role_defaults.each { |key, value| vars_context[key] ||= value } unless @all_role_defaults.empty?

      # Both role-vars layers sit above play/host vars but BELOW a
      # REGISTERED variable: Ansible ranks registered vars (19) well
      # above role vars (15), and baseA already holds them. Verified
      # against ansible-core 2.19.4 - a task that registers into a name
      # its own role's vars/main.yml also defines resolves to the
      # REGISTERED result there, where this engine used to hand back the
      # role var and lose the command's output entirely.
      registered = @registered_vars[host.name]

      unless @all_role_vars.empty?
        @all_role_vars.each do |key, value|
          next if registered.has_key?(key)
          vars_context[key] = value
        end
      end

      if role_vars = task.role_vars
        role_vars.each do |key, value|
          next if registered.has_key?(key)
          vars_context[key] = value
        end
      end

      task.vars.each { |key, value| vars_context[key] = value }

      # Magic variables belong in vars_context itself, not only in the
      # copy VarSubstitutor makes. Bare conditions - `when:`,
      # `until:`, `changed_when:`, `failed_when:`, and `assert:`'s
      # `that:` (which is evaluated inside the plugin, against the "vars"
      # this context is serialized into) - are evaluated directly against
      # vars_context and never saw them, so `when: inventory_hostname ==
      # "web1"` silently skipped every task while
      # `when: "{{ inventory_hostname }} == web1"` worked.
      #
      # Applied after facts (baseB below, which the old code built this
      # exact tier ON TOP of), with the same precedence rules
      # VarSubstitutor#add_magic_variables uses - see there for why only
      # inventory_hostname is unconditional. base_context_b_for covers
      # included_vars + facts; these 3 magic keys stay uncached and
      # applied directly here - see that method's own comment for why.
      base_context_b_for(host).each { |key, value| vars_context[key] = value }
      vars_context["inventory_hostname"] = JSON::Any.new(host.name)
      # inventory_hostname_short - everything before the first dot. Was
      # entirely missing, so `{{ inventory_hostname_short }}` raised.
      vars_context["inventory_hostname_short"] = JSON::Any.new(host.name.split('.').first)
      # group_names - the groups this host belongs to, parents included,
      # sorted. Was missing too (rendered empty).
      if inv = @inventory
        vars_context["group_names"] = JSON::Any.new(inv.groups_for(host.name).map { |name| JSON::Any.new(name) })
      end
      # ansible_host is inventory-derived (defaults to the inventory name);
      # ansible_hostname is a fact, undefined until real fact-gathering
      # populates it (facts land in this context via base_context_b_for) -
      # fabricating it made `ansible_hostname | default(...)` guards
      # silently wrong before facts were gathered.
      vars_context["ansible_host"] ||= JSON::Any.new(host.name)

      if role_name = task.role_name
        vars_context["ansible_role_name"] = JSON::Any.new(role_name)
        # role_name (unprefixed) is Ansible's own magic var - the
        # sibling role_path below has always been set unprefixed, this
        # one was only ever set under its ansible_ alias, so `{{
        # role_name }}` inside a role's own templates/tasks raised
        # "undefined" (akkerman.docker round 90029: `pin docker
        # version`'s template references it directly).
        vars_context["role_name"] = JSON::Any.new(role_name)
      end
      if parent_names = task.role_parent_names
        vars_context["ansible_parent_role_names"] = JSON::Any.new(parent_names.map { |nval| JSON::Any.new(nval) })
      end
      if collection_name = task.ansible_collection_name
        vars_context["ansible_collection_name"] = JSON::Any.new(collection_name)
      end
      if role_path = task.role_path
        vars_context["role_path"] = JSON::Any.new(role_path)
      end

      # ansible_search_path - Ansible's own job var
      # (task_executor.py sets it to Task#get_search_path() plus the
      # loader basedir when not already present): the role dependency
      # chain, current role first, then the directory of the file the
      # task lives in. The template action plugin's controller-side src
      # lookup and its "Searched in:" list are built from this.
      search_path = Krikri::NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task))
      basedir = File.expand_path(@playbook_dir)
      search_path << basedir unless search_path.includes?(basedir)
      vars_context["ansible_search_path"] = JSON::Any.new(search_path.map { |path| JSON::Any.new(path) })

      # `ansible_facts` - the same facts again, under their unprefixed
      # names, as one dict. Ansible exposes every fact both ways
      # (`ansible_os_family` *and* `ansible_facts.os_family`), and the
      # dict form is what modern roles use: dev-sec's os_hardening
      # references `ansible_facts.os_family` 16 times and never uses the
      # flat spelling, so without this every one of its conditions
      # silently evaluated false and the role skipped almost entirely.
      #
      # Derived from the same store rather than gathered separately, so
      # the two spellings can never disagree, and memoized per host
      # (facts_dict_for) rather than rebuilt on every single task - see
      # that method's own comment for the invalidation contract.
      #
      # Always present, even before any fact exists (gather_facts: false):
      # ansible pre-seeds an empty dict, so `ansible_facts is defined` is
      # true and `ansible_facts['os_family']` fails with "no attribute",
      # not "'ansible_facts' is undefined".
      vars_context["ansible_facts"] = JSON::Any.new(facts_dict_for(host.name))

      vars_context["hostvars"] = JSON::Any.new(build_hostvars)
      vars_context["groups"] = JSON::Any.new(build_groups)

      # ansible_play_hosts_all/ansible_play_hosts - Ansible magic
      # vars: the former is every host still active in the CURRENT play
      # (not the whole inventory - `groups['all']` is inventory-wide,
      # this is play-scoped), the latter is the subset not yet run in
      # the current serial: batch (equal to the former whenever serial:
      # isn't in play, the overwhelming common case, and the only one
      # this engine models). Neither existed at all before - any {%
      # for host in ansible_play_hosts %} loop (a common idiom for
      # writing a peer-list file, e.g. xanmanning.k3s's own control-
      # node registration step) silently iterated ZERO times instead of
      # raising or erroring, so the loop's own file/output ended up
      # empty rather than failing loudly - found benchmarking exactly
      # that role's "Ensure ansible_facts['host'] is mapped to
      # inventory_hostname" (blockinfile: with a `{% for host in
      # ansible_play_hosts %}` block) writing an empty /tmp/inventory.txt,
      # which a LATER task's `grep ... /tmp/inventory.txt` then failed
      # against (no match in an empty file) - while Ansible-
      # playbook, which has always populated this var, succeeded.
      play_host_names = @hosts.map { |hval| JSON::Any.new(hval.name) }
      vars_context["ansible_play_hosts_all"] = JSON::Any.new(play_host_names)
      vars_context["ansible_play_hosts"] = JSON::Any.new(play_host_names)
      # play_hosts - Ansible's deprecated-but-still-supported alias
      # for ansible_play_hosts, still resolved today (deprecation warning
      # only, slated for removal in ansible-core 2.23). Same value, same
      # refresh - roles written against the old name (wezhai.minio's
      # minio_env.j2 does `{% for host in play_hosts %}` for cluster
      # mode) hard-fail with "'play_hosts' is undefined" without it,
      # while ansible-playbook renders the host list.
      vars_context["play_hosts"] = JSON::Any.new(play_host_names)
      vars_context["ansible_version"] = ANSIBLE_VERSION_MAGIC_VAR
      # ansible_check_mode - Ansible magic var (true under --check,
      # false on a real run), entirely unimplemented before.
      # ansible-role idioms reference it directly (`when: not ansible_
      # check_mode`, `changed_when: not ansible_check_mode` for a task
      # whose action can't run at all in check mode) - a bare dotted-
      # free lookup, same "undefined" gap class as ansible_version.
      # Found live benchmarking geerlingguy.apache-php-fpm (round 164):
      # `ansible.builtin.file`'s own module-arg handling (via the
      # apache role's "Remove default vhost" task) references it and
      # hard-failed ("'ansible_check_mode' is undefined") under 0.9.517's
      # strict module-arg templating.
      vars_context["ansible_check_mode"] = JSON::Any.new(@check_mode)
      # ansible_diff_mode - Ansible magic var (true under --diff),
      # the same gap class as ansible_check_mode right above (bound
      # there but not here, so an idiom pairing the two in one
      # conditional half-worked). Found benchmarking
      # linux-system-roles.firewall round 970345: its "Show diffs" task
      # guards with `when: ansible_check_mode or ansible_diff_mode or
      # ...`, which hard-failed ("'ansible_diff_mode' is undefined")
      # where ansible-playbook just skips.
      vars_context["ansible_diff_mode"] = JSON::Any.new(@diff_mode)
      vars_context["ansible_verbosity"] = JSON::Any.new(@verbosity.to_i64)
      vars_context["ansible_play_name"] = JSON::Any.new(Krikri::RunOptions.play_name)
      vars_context["ansible_inventory_sources"] = JSON::Any.new(Krikri::RunOptions.inventory_sources.map { |source| JSON::Any.new(source) })
      run_tags = Krikri::RunOptions.run_tags
      vars_context["ansible_run_tags"] = JSON::Any.new((run_tags.empty? ? ["all"] : run_tags).map { |tag| JSON::Any.new(tag) })
      vars_context["ansible_skip_tags"] = JSON::Any.new(Krikri::RunOptions.skip_tags.map { |tag| JSON::Any.new(tag) })
      vars_context["ansible_forks"] = JSON::Any.new((Krikri::RunOptions.forks || 5).to_i64)
      # environment - ansible-core 2.19.11 resolves the play/task
      # `environment:` keyword as an ordinary variable inside task
      # templating, defaulting to an empty list when nothing sets it
      # (live-verified: `debug: msg: "Command = {{ environment }} x"` on
      # a task with no environment: renders "Command = [] x"). Left
      # unbound, `{{ environment }}` hard-failed with "'environment' is
      # undefined". Every user layer already merged above (play vars,
      # vars_files, role/task vars, included_vars/facts) still wins via
      # the has_key? check; the block-tag renderer's os.environ mapping
      # (JinjaRenderer#render_measured!) is an explicit render scope,
      # which the engine consults BEFORE this resolver-backed value, so
      # the GROG.debug-variable idiom keeps seeing the controller's ENV.
      vars_context["environment"] = JSON::Any.new([] of JSON::Any) unless vars_context.has_key?("environment")
      apply_path_magic_vars(vars_context)

      # ansible_connection - Ansible always resolves this magic var
      # (defaults "smart", which itself resolves to "ssh" for a remote
      # host, "local" for the controller) even when nothing sets it
      # explicitly (verified against ansible-playbook: `{{
      # ansible_connection }}` renders "ssh" on a bare inventory entry
      # with no ansible_connection= at all). Previously left entirely
      # undefined unless inventory/task explicitly set it, so a role's
      # own `when: ansible_connection not in [...]` (buluma.selinux's
      # block-level guard against running inside a container) hard-
      # failed with "'ansible_connection' is undefined" instead of
      # evaluating true, on every plain SSH host. `||=` so an explicit
      # inventory-set value (already merged into vars_context via
      # base_context_b_for above) or a prior magic-var write is never
      # clobbered; task.connection below still overrides unconditionally
      # since that's this ONE task's own explicit override.
      vars_context["ansible_connection"] ||= JSON::Any.new(
        PluginManager.local_connection?(host, vars_context) ? "local" : "ssh"
      )

      # loop_lenient_vars: a LOOPED task's vars: must not hard-fail on the
      # pre-loop render. Ansible only ever evaluates a looped task's
      # vars: per actual loop iteration (item bound) - a zero-iteration
      # loop (stackhpc.luks round 960004: `with_items: "{{ luks_devices }}"`
      # over the role's empty `luks_devices: []` default, vars: calling the
      # role-local `item | luks_key` filter) never evaluates them AT ALL,
      # and a non-empty loop re-renders them per item in both loop paths
      # (executor_loops.cr restores the raw task.vars and re-renders with
      # `item` bound). The eager render here runs with `item` unbound, so
      # a filter that raises on None turned a should-be-skipped (or should-
      # be-fine) looped task into a bogus failure before the loop's real
      # iteration count was ever consulted. Lenient mode degrades the
      # filter failure to the same raise-to-absent delete a non-filter
      # error already gets: the var stays out of the pre-loop context
      # (loop-source resolution sees undefined, the honest verdict), and
      # the per-iteration re-render - or the zero-iteration skip - gives
      # the authoritative one.
      # Value-level complement (see UnsafeValues' own comment): record the
      # exact text of every brace-bearing string in this host's registered
      # results / set_facts / facts, so the same hostile text is refused a
      # re-render even after flowing through an author-defined template or
      # a set_fact copy. Only brace-bearing strings are recorded, so the
      # common case adds nothing.
      # Both registries are populated BEFORE rendering task-level vars:
      # that render re-templates referenced vars through the resolver-
      # backed engine, and publishing only afterwards left the registries
      # holding the PREVIOUS task's state - which never includes a result
      # that previous task itself registered. `vars: {a: "{{ r.stdout }}"}`
      # then re-rendered a hostile stdout and ran its lookup on the
      # controller. The name registry is republished below once
      # task/extra vars are merged.
      @registered_vars[host.name].each_value { |value| UnsafeValues.mark_value(value) }
      @set_facts[host.name]?.try(&.each_value { |value| UnsafeValues.mark_value(value) })
      @facts[host.name].each_value { |value| UnsafeValues.mark_value(value) }
      VarSubstitutor.set_resolved_var_names(host.name, resolved_var_names_for(host, registered, vars_context))
      render_task_vars(task, vars_context, host.name, loop_lenient: loop_lenient_vars)

      # connection: local (or any other connection: override) on this
      # ONE task - independent of delegate_to:, which changes which
      # host's vars/facts apply rather than how the module runs. Every
      # local-vs-remote decision (PluginManager.local_connection?/
      # .remote_execution?, LocalExecutor vs SSHManager dispatch) reads
      # ansible_connection out of vars_context, so overriding it here
      # takes effect for this task's own dispatch without mutating the
      # host's own persistent vars. Previously entirely unparsed -
      # `connection: local` silently had no effect, running the task's
      # module against the real target over SSH instead of locally on
      # the controller. Found via robertdebock.backup's own "Create
      # backup_directory" task.
      if task_connection = task.connection
        vars_context["ansible_connection"] = JSON::Any.new(task_connection)
      end

      # remote_user: - the connection user, surfaced as ansible_user
      # exactly as Ansible does (verified: a play-level
      # `remote_user: playuser` renders `{{ ansible_user }}` as
      # playuser, and a task's own remote_user: overrides it for that
      # task). Applied before extra-vars below, which still outrank it.
      if user = task.remote_user || @remote_user
        vars_context["ansible_user"] = JSON::Any.new(user)
      end

      # Last word, deliberately: -e/--extra-vars outranks every other
      # scope, including a `set_fact` executed earlier in the same play
      # (facts arrive via base_context_b above, so applying these after
      # it is what reproduces Ansible's "you cannot set_fact over an
      # extra-var" behavior).
      @extra_vars.each { |key, value| vars_context[key] = value }

      # The SSH connection keys are read DIRECTLY out of this hash by
      # ConnectionSettings.resolve (controller-side dispatch, batching,
      # upload caching) - long before per-param templating ever runs - so
      # a templated value (`ansible_user: "{{ deploy_user }}"`, the
      # common real-role shape) would otherwise reach the ssh command
      # line literally. Render them HERE, once, against the fully merged
      # context, exactly where Ansible's connection plugin renders its
      # own option vars. A render failure (undefined reference) leaves
      # the raw template in place: the connection then fails loudly
      # against a garbage user/port rather than silently falling back to
      # the inventory's identity - the silent fallback is the original
      # task-level-vars bug this whole feature exists to fix.
      ConnectionSettings::CONNECTION_VAR_KEYS.each do |key|
        next unless (value = vars_context[key]?) && (text = value.as_s?) && text.includes?("{{")
        begin
          vars_context[key] = JSON::Any.new(Krikri::VarSubstitutor.new(vars: vars_context).substitute(text))
        rescue
        end
      end

      # Publish this host's execution-resolved (unsafe) variable names for
      # the re-templating gate - see VarSubstitutor's @@resolved_var_names
      # comment. Published here, AFTER every var layer, so the
      # fact-sourced entries below can tell a genuinely fact-sourced value
      # from an author override: any name whose final context value differs
      # from the fact store's was overwritten by a higher-precedence
      # author-defined template and stays safely re-renderable (Ansible only marks what the MODULE returned). Covers:
      # - every `register:` write (@registered_vars keys)
      # - every `set_fact:` write (@set_facts keys)
      # - every gathered fact (@facts keys - ansible_os_family,
      #   ansible_local, ansible_env, ... - the whole hostile-target
      #   surface, local .fact files included)
      # - the `ansible_facts` dict spelling of the same facts
      # - the `ansible_facts` dict spelling of the same facts
      VarSubstitutor.set_resolved_var_names(host.name, resolved_var_names_for(host, registered, vars_context))

      # Ansible's `vars` magic variable: a dict of every variable in
      # scope, most often used for a membership test rather than to read
      # a value - `prometheus.prometheus`'s own preflight does
      # `__common_parent_role_short_name ~ '_skip_install' not in vars`,
      # which is what surfaced its absence (round 198: crystal failed
      # that task with "'vars' is undefined" while ansible-playbook
      # completed all 33 tasks, blocking the whole collection).
      #
      # Built LAST so it sees every other magic var, and deliberately
      # excludes itself - `vars["vars"]` would be an infinite structure,
      # and Ansible does not expose one either.
      #
      # Cheap despite appearances: JSON::Any wraps a reference, so this
      # is a hash of N pointer copies, not a deep copy of the context.
      # Skipping "vars" is not belt-and-braces: vars_context is layered
      # on cached base contexts (see base_context_a/b), so an earlier
      # task's `vars` key is genuinely present here and would nest one
      # snapshot inside the next, growing per task. Verified against
      # ansible-core 2.19.4, which reports `'vars' not in vars`.
      self_view = Hash(String, JSON::Any).new(initial_capacity: vars_context.size)
      vars_context.each do |key, value|
        next if key == "vars"
        self_view[key] = value
      end
      vars_context["vars"] = JSON::Any.new(self_view)

      vars_context
    end

    # Names whose current value came from EXECUTION (register:, set_fact:,
    # gathered facts) for *host* - see VarSubstitutor.set_resolved_var_names.
    # A fact name the author overrides with a different value in
    # *vars_context* is author data again and stays re-renderable.
    private def resolved_var_names_for(host : Host, registered : Hash(String, JSON::Any), vars_context : Hash(String, JSON::Any)) : Set(String)
      resolved_names = Set(String).new(registered.keys)
      @set_facts[host.name]?.try(&.each_key { |key| resolved_names.add(key) })
      set_fact_keys = @set_facts[host.name]?
      @facts[host.name].each do |key, value|
        next if set_fact_keys.try(&.has_key?(key))
        next if registered.has_key?(key)
        next if (ctx_val = vars_context[key]?) && ctx_val != value
        resolved_names.add(key)
      end
      resolved_names.add("ansible_facts") unless @facts[host.name].empty?
      resolved_names
    end

    # The template expression *source* is a direct data reference if it is
    # either exactly one `{{ ... }}` span with no author literal text
    # around it, or contains no template markers at all and is an
    # identifier-led expression. Anything else - a literal list element
    # like `"{{ ansible_os_family }}.yml"` (literal `.yml` around the span),
    # a multi-span string, a `{%`-block form - carries AUTHOR template text
    # and is never a taint source. Returns the expression text to scan for
    # referenced identifiers, or nil.
    private def direct_reference_expression?(source : String) : String?
      stripped = source.strip
      return nil unless stripped.includes?("{{")
      return nil unless stripped.starts_with?("{{") && stripped.ends_with?("}}")
      return nil unless stripped.scan("{{").size == 1
      return nil if stripped.includes?("{%") || stripped.includes?("{#")
      inner = stripped[2..-3].strip
      return nil if inner.empty? || inner.includes?("{{") || inner.includes?("}}")
      inner
    end

    # Ansible's variable manager treats `ansible_ssh_user`/
    # `ansible_ssh_host`/`ansible_ssh_port` as deprecated-but-still-
    # honored aliases of `ansible_user`/`ansible_host`/`ansible_port` -
    # but only in the FINAL task-argument templating context. Loop-source
    # resolution (and the loop items it recursively renders) sees an
    # earlier vars snapshot where the synthesis never happened, so
    # `loop: ["{{ ansible_ssh_user }}"]` - or a role default like
    # f500.bashrc's own `bashrc_users: ["{{ ansible_ssh_user }}"]`
    # (round900321) later fed to `with_items:` - hard-fails with
    # "'ansible_ssh_user' is undefined" on ansible-playbook, while
    # the same reference in a plain task arg (or a `when:`, or a role
    # default reached through task-arg templating - round168's
    # geerlingguy.phergie `phergie_user: "{{ ansible_ssh_user }}"`
    # default feeding `file: {owner: "{{ phergie_user }}"}`) resolves
    # fine. Live-verified all four shapes against ansible-playbook
    # this session. This engine used to synthesize the aliases inside the
    # cached baseA layer, making them visible to EVERYTHING - which
    # resolved f500.bashrc's defaults the way phergie's resolve, where
    # Ansible fails them. Synthesized with `||=` in both directions,
    # so an inventory line that already sets the legacy spelling
    # explicitly still wins and stays a REAL variable - visible in loop
    # sources too, exactly as Ansible treats an explicitly-set var.
    private def synthesize_legacy_ssh_aliases(vars_context : Hash(String, JSON::Any)) : Nil
      if user = vars_context["ansible_user"]?
        vars_context["ansible_ssh_user"] ||= user
      elsif ssh_user = vars_context["ansible_ssh_user"]?
        vars_context["ansible_user"] ||= ssh_user
      end
      if host_val = vars_context["ansible_host"]?
        vars_context["ansible_ssh_host"] ||= host_val
      elsif ssh_host = vars_context["ansible_ssh_host"]?
        vars_context["ansible_host"] ||= ssh_host
      end
      if port = vars_context["ansible_port"]?
        vars_context["ansible_ssh_port"] ||= port
      elsif ssh_port = vars_context["ansible_ssh_port"]?
        vars_context["ansible_port"] ||= ssh_port
      end
    end

    # The vars snapshot loop-SOURCE resolution must see: identical to the
    # task-arg context except that synthesized legacy ssh aliases are
    # absent (Ansible's own scoping - see #build_vars_context's
    # synthesis comment for the verified matrix). Cheap in the common
    # case: a full alias-free rebuild is only needed when a legacy
    # spelling is present at all - if none of the three keys is in the
    # context, neither a synthesized nor an explicit copy exists, so any
    # lookup resolves identically either way and the caller's own context
    # is returned as-is. An EXPLICITLY-set legacy spelling (inventory/
    # play vars/task vars) survives the rebuild - it's a real variable,
    # visible in loop sources exactly as Ansible treats it.
    #
    # The rebuild must stay loop-lenient (round962000, the confirm-phase
    # re-run of stackhpc.luks after the original loop_lenient_vars fix):
    # this context exists to resolve the loop SOURCE itself, so it is
    # built even earlier than the caller's pre-loop render - `item` is
    # doubly unbound here. Without the flag, a looped task's vars:
    # expression hitting a raising filter re-raised as an UNHANDLED
    # FilterFailureError (render_task_vars' UnknownFilterError branch
    # re-raises when not lenient) and crashed the whole process instead
    # of degrading to var-absent. Only this rebuild needs the flag here -
    # the early-return path hands back a context the caller already built
    # leniently.
    private def loop_source_vars_context(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      return vars_context unless {"ansible_ssh_user", "ansible_ssh_host", "ansible_ssh_port"}.any? { |key| vars_context.has_key?(key) }
      build_vars_context(task, host, include_legacy_ssh_aliases: false, loop_lenient_vars: task_has_loop?(task))
    end

    # First of the 2 #build_vars_context base caches - see the
    # @base_context_a_cache ivar's own comment for why there are 2 and
    # what order this preserves. @play_vars is fixed for this
    # TaskExecutor's whole lifetime (assigned once, in #initialize -
    # `grep -n '@play_vars\s*='` finds no other write); host.vars never
    # mutates mid-play either (audited the same way for item #16 above -
    # every `host.vars[...]` site in this file is a READ); leaving
    # @registered_vars[host.name] as this cache's only real input,
    # already covered by @hv_generation's own invalidation contract.
    private def base_context_a_for(host : Host) : Hash(String, JSON::Any)
      if @base_context_a_generation[host.name]? == @hv_generation
        return @base_context_a_cache[host.name]
      end

      result = Hash(String, JSON::Any).new(initial_capacity: 128)
      @play_vars.each { |key, value| result[key] = value }
      host.vars.each { |key, value| result[key] = value }
      @registered_vars[host.name].each { |key, value| result[key] = value }

      # (round168's geerlingguy.phergie) sees the SAME value either way
      # in task-arg templating. The synthesis itself lives in
      # #build_vars_context now, not here: baseA is cached and shared by
      # every consumer, but Ansible's alias synthesis is visible
      # only in final task-arg templating - loop-source resolution (and
      # the loop items it recursively renders) sees a vars snapshot
      # without it (round900321 f500.bashrc's
      # `bashrc_users: ["{{ ansible_ssh_user }}"]` default fails
      # `with_items: "{{ bashrc_users }}"` on ansible-playbook).
      # See #build_vars_context's own synthesis comment for the full
      # verified matrix.

      # Ordinary gathered facts (setup:/package_facts:/service_facts:/
      # etc, i.e. everything in @facts that ISN'T also in @set_facts)
      # fill in here LAST, via `||=` - Ansible's "host facts" tier
      # sits below play vars/inventory vars/registered vars, so any of
      # those already present in `result` must win. A key present in
      # BOTH @facts and @set_facts (the set_fact case) is skipped here
      # entirely; base_context_b_for applies it unconditionally at the
      # correct high tier instead.
      set_fact_keys = @set_facts[host.name]?
      @facts[host.name].each do |key, value|
        next if set_fact_keys.try(&.has_key?(key))
        result[key] ||= value
      end

      @base_context_a_cache[host.name] = result
      @base_context_a_generation[host.name] = @hv_generation
      result
    end

    # Second of the 2 #build_vars_context base caches - included_vars +
    # facts, applied in that exact relative order so a same-key
    # collision between them resolves identically to the pre-cache code
    # (which merged them in this same sequence). Deliberately does NOT
    # also cache the 3 host-magic keys (inventory_hostname/
    # ansible_hostname/ansible_host) the old code applied right after -
    # unlike included_vars/facts, those 2 `||=`s need to see whatever
    # `host.vars` (baseA, merged into vars_context BEFORE this cache) may
    # already have set for the SAME keys (an inventory line like `web1
    # ansible_host=192.0.2.55` must win). A `||=` evaluated only against
    # THIS method's own small hash - which has no idea what baseA already
    # put in vars_context - would set them unconditionally instead,
    # clobbering the real inventory value; caught by
    # `cli_spec.cr`'s own "does not overwrite an inventory ansible_host
    # with the inventory name" spec. Cheap enough (3 conditional
    # assignments) to just apply directly against the real vars_context
    # in #build_vars_context instead of caching. All real inputs here are
    # covered by @hv_generation's existing invalidation contract -
    # @included_vars gained a bump site at #execute_include_vars (its
    # only writer) as part of this change; @facts was already covered by
    # facts_dict_for above.
    private def base_context_b_for(host : Host) : Hash(String, JSON::Any)
      if @base_context_b_generation[host.name]? == @hv_generation
        return @base_context_b_cache[host.name]
      end

      result = Hash(String, JSON::Any).new(initial_capacity: 128)
      @included_vars[host.name]?.try(&.each { |key, value| result[key] = value })
      @failure_vars[host.name]?.try(&.each { |key, value| result[key] = value })
      # Only the set_fact subset rides at this high tier - see the
      # @set_facts ivar comment. Ordinary gathered facts (setup:/
      # package_facts:/service_facts:/etc) are filled in at the LOW
      # tier instead, inside base_context_a_for.
      @set_facts[host.name]?.try(&.each { |key, value| result[key] = value })

      @base_context_b_cache[host.name] = result
      @base_context_b_generation[host.name] = @hv_generation
      result
    end

    # Memoized "ansible_facts.*" dict for one host - see
    # build_vars_context's own comment for why this dict has to exist
    # separately from the flat `ansible_os_family`-style keys already in
    # @facts[host.name].
    #
    # Invalidation contract: @facts[host.name] has exactly 3 real
    # mutation sites in this file (audited directly, not assumed -
    # `grep -n '@facts\[.*\]\s*=\|@facts\[.*\]\.clear' executor.cr`) -
    # gather_facts's full replace, merge_ansible_facts's per-key write
    # (the path set_fact:/package_facts:/etc all go through), and meta:
    # clear_facts's #clear. Every one of the 3 deletes this host's cache
    # entry (`@facts_dict_cache.delete(host.name)`) in the same
    # statement that mutates @facts, so the next call here always sees a
    # cache miss and rebuilds from the fresh @facts contents - there is
    # no 4th mutation site to miss (unlike the general vars_context
    # caching in item #1 of SUGGESTED_PERFORMANCE_IMPROVEMENTS.md, which
    # this deliberately does NOT attempt: task.vars/role_vars/
    # role_defaults vary per TASK, not just per host, and that item's own
    # writeup flags exactly why a full-context cache needs a much more
    # exhaustive invalidation audit than this narrow one).
    private def facts_dict_for(host_name : String) : Hash(String, JSON::Any)
      @facts_dict_cache[host_name] ||= begin
        facts_dict = Hash(String, JSON::Any).new(initial_capacity: 128)
        @facts[host_name].each do |key, value|
          # ansible_local is the ONE fact real Ansible keeps its ansible_
          # prefix inside the ansible_facts dict (`ansible_facts
          # ['ansible_local']` is defined and `ansible_facts['local']` is
          # NOT - live-verified against ansible-core 2.19.11, where a
          # key-listing debug over a fully gathered host shows ansible_local
          # as the only ansible_-prefixed survivor). Oefenweb.mydumper's
          # build-skip chain (`ansible_facts['ansible_local'] is not
          # defined or ...`, round 5460204 warm phase) short-circuited true
          # on the first clause here because this dict had stripped the
          # prefix to 'local', re-running the whole source build on hosts
          # where the role's own facts.d file already reported the built
          # version.
          facts_dict[key == "ansible_local" ? "ansible_local" : key.lchop("ansible_")] = value
        end
        facts_dict
      end
    end

    # Ansible's `groups` magic variable - a dict of every inventory
    # group name to the list of host names it contains (`groups['all']`,
    # `groups['webservers']`, ...), the standard way a task broadcasts to
    # or loops over every host in a group without hardcoding names
    # (geerlingguy.kubernetes' own "Set the kubeadm join command
    # globally.": `delegate_to: "{{ item }}", loop: "{{ groups['all'] }}"`
    # to push the join command onto every node). Previously not populated
    # at all, so ANY `groups[...]` access resolved "undefined" - a single-
    # item loop whose one item literally was the string "undefined",
    # which a templated `delegate_to: "{{ item }}"` then tried to SSH to.
    #
    # `groups['all']` is synthesized from the full inventory (not merely
    # `@inventory.groups["all"]?`, which may not even exist as an
    # explicit group) - matches Ansible, where 'all' always means
    # every host regardless of how the inventory file grouped things.
    private def build_groups : Hash(String, JSON::Any)
      if (cache = @groups_cache) && @groups_cache_generation == @hv_generation
        return cache
      end

      result = Hash(String, JSON::Any).new
      if inventory = @inventory
        inventory.groups.each do |name, _group|
          # hosts_in_group, not group.hosts: a parent group defined via
          # Observed behavior: children has an empty hosts hash of its own, so groups['prod']
          # came back as [] for every such group.
          result[name] = JSON::Any.new(inventory.hosts_in_group(name).map { |host| JSON::Any.new(host.name) })
        end
        result["all"] = JSON::Any.new(inventory.hosts.keys.map { |hostname| JSON::Any.new(hostname) })
        # ungrouped - Ansible's own groups magic var always carries
        # it (every host not in any named group), and lookup('inventory_
        # hostnames', 'ungrouped') matches against it like any other
        # group. Previously missing, so groups['ungrouped'] rendered
        # "undefined".
        result["ungrouped"] = JSON::Any.new(
          inventory.hosts.keys.reject { |hostname|
            inventory.groups.keys.any? { |name| name != "all" && name != "ungrouped" && inventory.hosts_in_group(name).map(&.name).includes?(hostname) }
          }.map { |hostname| JSON::Any.new(hostname) }
        )
      else
        result["all"] = JSON::Any.new(@hosts.map { |other_host| JSON::Any.new(other_host.name) })
        result["ungrouped"] = JSON::Any.new(@hosts.map { |other_host| JSON::Any.new(other_host.name) })
      end
      @groups_cache = result
      @groups_cache_generation = @hv_generation
      result
    end

    # Ansible's `hostvars[<name>]` magic variable - a dict of every
    # host in the *whole inventory's* own vars (inventory-defined vars
    # like ansible_host, any facts already gathered for it, and any
    # vars it has registered so far), letting a task on one host look
    # up another's connection details or state
    # (`hostvars['node2'].ansible_host`) - the standard hand-written
    # task shape every real multi-node Ansible playbook uses for
    # cross-host orchestration (peer-probing a GlusterFS/etcd/Consul
    # cluster's other members, templating a load balancer config from
    # every backend's own facts, ...). Previously not populated at all,
    # so `hostvars[...]` always resolved "undefined" - found
    # benchmarking a real geerlingguy.glusterfs 3-node cluster: `gluster
    # peer probe {{ hostvars['node2'].ansible_host }}` ran as `gluster
    # peer probe undefined`, silently probing a bogus hostname instead
    # of the real peer's IP.
    #
    # Deliberately sourced from @inventory.hosts (the FULL inventory),
    # not @hosts (only this play's own `hosts:` pattern target list) -
    # real hostvars is available for any inventory host, including ones
    # a given play never targets itself (the glusterfs cluster playbook
    # above: only node1 runs the peer-probe play, but needs node2/
    # node3's hostvars too). Falls back to @hosts when there's no
    # inventory reference at all (the async-job replay path constructs
    # TaskExecutor without one) - covering only the current play's
    # hosts there is still strictly better than not populating hostvars
    # at all.
    #
    # Rebuilt fresh on every #build_vars_context call (once per task per
    # host) rather than cached - Ansible's own hostvars reflects a
    # set_fact:/register: made by ANY host earlier in the same play, so
    # a stale snapshot would miss updates. Deliberately narrower than a
    # full recursive #build_vars_context call per other host (which
    # would also need its own "hostvars" key excluded to avoid infinite
    # recursion) - inventory vars + facts + registered vars + set_facts
    # covers every real-world hostvars[...] use seen so far.
    # playbook_dir / inventory_dir / inventory_file - Ansible's path
    # magic vars, all three ABSOLUTE regardless of how the paths were
    # spelled on the command line (verified against ansible-core 2.19.4
    # with a relative playbook and a relative inventory run from a third
    # directory). Roles use `playbook_dir` to reach files relative to the
    # playbook rather than the working directory; without it, `{{
    # playbook_dir }}` failed outright here ("'playbook_dir' is
    # undefined") under strict module-arg templating.
    #
    # With no inventory, `inventory_dir`/`inventory_file` are left
    # UNDEFINED rather than set to empty strings - also verified against
    # Ansible - so a role's `inventory_file is defined` guard reads
    # the same here. A DIRECTORY inventory sets `inventory_dir` to the
    # directory itself and `inventory_file` to its single source file,
    # leaving the latter undefined when several sources make "the"
    # inventory file ambiguous.
    #
    # Both of those shapes are handled here but not reachable yet: this
    # engine's inventory loader defaults to `inventory.ini` instead of
    # Ansible's implicit localhost when `-i` is omitted, and cannot
    # load a directory of inventory sources at all (it tries to execute
    # it as a dynamic inventory script). Those are separate, pre-existing
    # gaps in the loader, not in these magic vars.
    # The directory of the file the task lives in - Ansible's
    # `dirname(task.get_path())`, the last entry of the search stack.
    # Role-file tasks have no source_file stamp (role_loader passes
    # none), so fall back to the including task file's directory and
    # then the role's own tasks/ directory - Ansible's task dir for a
    # role's main.yml tasks.
    private def needle_task_file_dir(task : Task) : String?
      if file = task.source_file
        return File.dirname(file)
      end
      if dir = task.include_file_dir
        return dir
      end
      if role = task.role_path
        return File.join(role, "tasks")
      end
      nil
    end

    private def apply_path_magic_vars(vars_context : Hash(String, JSON::Any)) : Nil
      vars_context["playbook_dir"] = JSON::Any.new(File.expand_path(@playbook_dir))

      return unless path = @inventory_path
      absolute = File.expand_path(path)

      if File.directory?(absolute)
        vars_context["inventory_dir"] = JSON::Any.new(absolute)
        sources = Dir.children(absolute).map { |child| File.join(absolute, child) }.select { |child| File.file?(child) }
        vars_context["inventory_file"] = JSON::Any.new(sources.first) if sources.size == 1
      else
        vars_context["inventory_dir"] = JSON::Any.new(File.dirname(absolute))
        vars_context["inventory_file"] = JSON::Any.new(absolute)
      end
    end

    private def build_hostvars : Hash(String, JSON::Any)
      if (cache = @hostvars_cache) && @hostvars_cache_generation == @hv_generation
        return cache
      end

      result = Hash(String, JSON::Any).new
      all_hosts = @inventory.try(&.hosts.values) || @hosts
      all_hosts.each do |other_host|
        entry = Hash(String, JSON::Any).new
        other_host.vars.each { |key, value| entry[key] = value }
        @facts[other_host.name]?.try(&.each { |key, value| entry[key] = value })
        @registered_vars[other_host.name]?.try(&.each { |key, value| entry[key] = value })
        # set_facts rank ABOVE both (Ansible's "set_facts / registered
        # vars" tier sits near the very top of the precedence ladder), so
        # they merge last. They also land in @facts via
        # merge_ansible_facts, but the run-scoped store's re-gather merges
        # rather than the entry staying hand-synced with @set_facts - a
        # host whose play-2 re-gather ran while a play-1 set_fact exists
        # must still show the set_fact value here (verified against
        # ansible-core 2.19.11).
        @set_facts[other_host.name]?.try(&.each { |key, value| entry[key] = value })
        entry["inventory_hostname"] = JSON::Any.new(other_host.name)
        # Ansible's hostvars view carries the play magic variables on
        # EVERY host's entry (verified live against ansible-core 2.19.11:
        # an add_host-created host's entry holds inventory_hostname_short,
        # group_names, groups, playbook_dir, inventory_dir, inventory_file,
        # ansible_version, ansible_check_mode/diff_mode, ansible_forks,
        # ansible_play_name, ansible_inventory_sources, ansible_run_tags,
        # ansible_skip_tags, ansible_verbosity, ansible_play_hosts_all/
        # ansible_play_hosts/play_hosts alongside its own vars). This
        # engine's entries historically carried only inventory_hostname +
        # the host's own vars - reads through hostvars fell back to the
        # READING host's scope for everything else (HostvarsContext), so a
        # cross-host read of a PER-HOST magic var (group_names most
        # prominently) silently returned the reading host's value. The
        # add_host path diverged hardest (the new host's groups are
        # invisible to every other host's hostvars read) and was enriched
        # first; ordinary inventory hosts kept the fallback - but the
        # fallback only exists for the hand-rolled evaluators. The JINJA
        # template path turns each hostvars entry into a plain dict
        # (prepare_hostvars), so `hostvars[inventory_hostname].
        # group_names[0]` on an ordinary inventory host died with
        # "object of type 'dict' has no attribute 'group_names'"
        # (bilalcaliskan.redis's redis.conf.j2, round 5210000). Every
        # host's entry now carries the full play-magic set, exactly like
        # real's hostvars view.
        enrich_add_host_entry(entry, other_host)
        # No synthesized ansible_host here: Ansible's hostvars magic
        # view carries ONLY actually-defined vars (inventory + facts +
        # registered), and `{{ ansible_host }}` falls back to the
        # inventory hostname through the CONNECTION-var path
        # (vars_context["ansible_host"] ||= host.name further down), not
        # through hostvars. Verified live against ansible-core 2.19.11:
        # a host whose inventory defines no ansible_host has NO
        # ansible_host key in hostvars[h] (and
        # `map('extract', hostvars, 'ansible_host')` hard-fails with
        # "object of type 'HostVarsVars' has no attribute 'ansible_host'"),
        # while `{{ ansible_host }}` on the current host still renders the
        # hostname. The synthesis used to feed exactly that extract shape
        # a fabricated value, letting a bad-inventory playbook
        # Ansible aborts on task 1 run on with hostname garbage in place
        # of the IP list.
        result[other_host.name] = JSON::Any.new(entry)
      end
      # ansible-core's InventoryManager ALWAYS synthesizes an implicit
      # "localhost" pseudo-host when no inventory defines one, and exposes it
      # via hostvars['localhost'] from ANY play - even one targeting entirely
      # different machines (verified live against ansible-core 2.19.11: the
      # implicit entry carries inventory_hostname/inventory_hostname_short,
      # group_names: [], ansible_host, ansible_connection: local, and no
      # inventory_file). round900712 gzm55.require_implicity_localhost asserts
      # exactly that absence from a play targeting a remote host and failed
      # here with "object of type 'dict' has no attribute 'localhost'" - this
      # is the hostvars-visibility slice of implicit localhost only, not the
      # inventory-loader-level gap noted above apply_path_magic_vars (the
      # loader still defaults to inventory.ini instead of implicit localhost
      # when -i is omitted). An explicitly inventory-defined localhost keeps
      # its real entry untouched, matching Ansible's explicit-over-
      # implicit precedence, and no facts are gathered for the implicit one -
      # nothing runs against it unless a task explicitly targets localhost.
      unless result.has_key?("localhost")
        implicit = Hash(String, JSON::Any).new
        implicit["inventory_hostname"] = JSON::Any.new("localhost")
        implicit["inventory_hostname_short"] = JSON::Any.new("localhost")
        implicit["group_names"] = JSON::Any.new(Array(JSON::Any).new)
        implicit["ansible_host"] = JSON::Any.new("localhost")
        implicit["ansible_connection"] = JSON::Any.new("local")
        result["localhost"] = JSON::Any.new(implicit)
      end
      @hostvars_cache = result
      @hostvars_cache_generation = @hv_generation
      result
    end

    # Adds the play magic variables to an add_host-created host's hostvars
    # entry, mirroring what build_vars_context lays on every CURRENT host
    # (the same sources, so the two can never disagree): the per-host
    # ones from the entry host itself (inventory_hostname_short,
    # group_names), the play-scoped ones from this executor's state and
    # RunOptions. ansible_playbook_python and ansible_config_file are NOT
    # synthesized (this engine defines neither anywhere - fabricating a
    # python path would be worse than the absence), and ansible_facts
    # only ever appears when facts were actually gathered for the host,
    # both matching the entry conventions above.
    private def enrich_add_host_entry(entry : Hash(String, JSON::Any), host : Host) : Nil
      entry["inventory_hostname_short"] = JSON::Any.new(host.name.split('.').first)
      if inv = @inventory
        entry["group_names"] = JSON::Any.new(inv.groups_for(host.name).map { |name| JSON::Any.new(name) })
      end
      entry["groups"] = JSON::Any.new(build_groups)
      # Ansible's entry carries the ansible_facts dict form too - an empty
      # dict when no facts were ever gathered for the host (live-verified
      # vs 2.19.11), the gathered dict otherwise.
      entry["ansible_facts"] = JSON::Any.new(@facts[host.name]? ? facts_dict_for(host.name) : Hash(String, JSON::Any).new)
      apply_path_magic_vars(entry)
      entry["ansible_version"] = ANSIBLE_VERSION_MAGIC_VAR
      entry["ansible_check_mode"] = JSON::Any.new(@check_mode)
      entry["ansible_diff_mode"] = JSON::Any.new(@diff_mode)
      entry["ansible_verbosity"] = JSON::Any.new(@verbosity.to_i64)
      entry["ansible_play_name"] = JSON::Any.new(Krikri::RunOptions.play_name)
      entry["ansible_inventory_sources"] = JSON::Any.new(Krikri::RunOptions.inventory_sources.map { |source| JSON::Any.new(source) })
      run_tags = Krikri::RunOptions.run_tags
      entry["ansible_run_tags"] = JSON::Any.new((run_tags.empty? ? ["all"] : run_tags).map { |tag| JSON::Any.new(tag) })
      entry["ansible_skip_tags"] = JSON::Any.new(Krikri::RunOptions.skip_tags.map { |tag| JSON::Any.new(tag) })
      entry["ansible_forks"] = JSON::Any.new((Krikri::RunOptions.forks || 5).to_i64)
      play_host_names = @hosts.map { |hval| JSON::Any.new(hval.name) }
      entry["ansible_play_hosts_all"] = JSON::Any.new(play_host_names)
      entry["ansible_play_hosts"] = JSON::Any.new(play_host_names)
      entry["play_hosts"] = JSON::Any.new(play_host_names)
    end

    # A task-level vars: value can itself be a template referencing other
    # vars (dev-sec os_hardening's own `vars: {mountinfo: "{{
    # ansible_facts.mounts | selectattr(...) | list | first | default(None)
    # }}"}`, computing a per-task helper from ansible_facts) -
    # VariableContext.build merges task.vars into the context as plain
    # unrendered strings (it runs before ansible_facts/magic vars even
    # exist), so without this a template-valued task var stayed literal
    # `"{{ ... }}"` text forever, and any {{ }}/when: referencing it
    # (`mountinfo.device`) resolved undefined. Rendered here, once the
    # context is fully assembled, so a task var can reference
    # ansible_facts/registered vars/other role vars - anything already in
    # scope by this point.
    # include_role:'s own vars: (unlike a block's or a plain task's vars:,
    # both handled by render_task_vars/propagate_role_context) were passed
    # to RoleLoader.load_single_role completely unrendered - a templated
    # value (linux-system-roles/logging's own `include_role: name: "{{
    # role_path }}/roles/rsyslog" vars: rsyslog_custom_config_files: "{{
    # __custom_config_files + logging_custom_config_files }}"`) landed in
    # the subrole's vars as the literal `"{{ ... }}"` text - a non-empty,
    # "defined" string instead of the empty list it should have rendered
    # to. Every task in the subrole referencing that var saw the raw
    # template text as its value; here that fed `loop: "{{
    # rsyslog_custom_config_files | flatten }}"`, turning a should-be-
    # empty (and thus skipped) loop into one bogus iteration whose `item`
    # was the whole unparsed template string, sent straight into `copy:
    # src: "{{ item }}"` and failing there instead.
    private def render_task_vars(task : Task, vars_context : Hash(String, JSON::Any), host_name : String, loop_lenient : Bool = false) : Nil
      task.vars.each_key do |key|
        raw = vars_context[key]?
        next unless raw

        # Miss signal for the strict-undefined keep-raw decision below:
        # a task-level `vars:` value whose render consumed a missing
        # attribute stays RAW, so real ansible-core 2.19's LAZY semantics
        # are preserved - the value renders at its USE site, and a strict
        # use (module-arg finalization) fails there with the attribute-
        # shaped error while a lenient use (task name, an `is defined`
        # guard, a skip) never renders it at all (live-verified matrix
        # vs 2.19.11). Deleting or pre-rendering "undefined" text would
        # both erase the distinction.
        signal_before = KrikriJinja.miss_count

        # Walk nested Hash/Array values too - a task-level `vars:` dict
        # like buluma.ara_api's `reconciled_configuration: { DEBUG:
        # "{{ ara_api_debug }}", DATABASE_CONN_MAX_AGE: "{{ ara_api_
        # database_conn_max_age }}", ... }` used to leave every nested
        # bare-mustache as an unevaluated STRING, so set_fact later
        # stored "False"/"0" instead of real bool/int and to_nice_yaml
        # wrote quoted strings Django rejected (round 190). Recursing
        # preserves the same type-preserving bare-mustache path the
        # top-level case already uses.
        begin
          vars_context[key] = render_task_var_value(raw, vars_context, host_name)
        rescue e : VariableSubstitutor::FilterEngine::UnknownFilterError
          unless loop_lenient
            # An unknown filter name is NOT a legitimate raise-to-absent
            # case: Ansible hard-fails the task that uses the var with
            # "No filter named 'X'." (a Jinja2 TemplateAssertionError -
            # Jinja validates filter names against its registered filter set
            # before ever calling). Silently dropping the var here fed the
            # downstream `default(...)` chain the literal text "undefined"
            # instead (nephelaiio.pip / nephelaiio.gitlab's own
            # `nephelaiio.plugins.sorted_get` set_fact: - `apt install
            # undefined`), a different, silently-wrong later failure.
            raise e
          end
          # Lenient (looped-task pre-loop) mode: see build_vars_context's
          # loop_lenient_vars comment - the per-iteration re-render (with
          # `item` bound) or the zero-iteration skip owns the real verdict.
          vars_context.delete(key)
        rescue
          # Same raise-to-absent convention as before: a vars: expression
          # that legitimately raises is dropped rather than crashing the
          # whole task when when: would have skipped it.
          vars_context.delete(key)
        end
        if KrikriJinja.miss_count > signal_before && strict_var_value_miss(raw, vars_context)
          vars_context[key] = raw
        end
      end
    end

    # The strict-undefined probe for a task-level `vars:` VALUE (see
    # render_task_vars): returns ansible's error message when rendering
    # this value would CONSUME a missing attribute/undefined name, nil
    # otherwise. Whole-single-span strings probe as expressions; mixed
    # text probes as a strict template render; containers probe each
    # template-string leaf.
    private def strict_var_value_miss(raw : JSON::Any, vars_context : Hash(String, JSON::Any)) : String?
      r = raw.raw
      if r.is_a?(String)
        return nil unless r.includes?("{{") || r.includes?("{%") || r.includes?("{#")
        stripped = r.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
          Krikri.strict_undefined_probe_message(stripped[2..-3].strip, vars_context)
        else
          VariableSubstitutor::JinjaRenderer.strict_render_undefined_message(r, vars_context)
        end
      elsif r.is_a?(Array)
        raw.as_a.each do |entry|
          miss = strict_var_value_miss(entry, vars_context)
          return miss if miss
        end
        nil
      elsif r.is_a?(Hash)
        raw.as_h.each_value do |entry|
          miss = strict_var_value_miss(entry, vars_context)
          return miss if miss
        end
        nil
      end
    end

    private def render_task_var_value(value : JSON::Any, vars_context : Hash(String, JSON::Any), host_name : String) : JSON::Any
      case raw = value.raw
      when Hash
        result_hash = Hash(String, JSON::Any).new
        raw.each { |k, v| result_hash[k] = render_task_var_value(v, vars_context, host_name) }
        JSON::Any.new(result_hash)
      when Array
        JSON::Any.new(raw.map { |v| render_task_var_value(v, vars_context, host_name) })
      when String
        return value unless raw.includes?("{{")

        if native = evaluate_bare_mustache_preserving_type(raw, vars_context)
          return native
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        rendered = substitutor.substitute(raw)
        parsed = (rendered.starts_with?('{') || rendered.starts_with?('[')) ? (JSON.parse(rendered) rescue nil) : nil
        parsed || JSON::Any.new(rendered)
      else
        value
      end
    end

    # A raw value that's EXACTLY one bare `{{ expr }}` span (nothing else
    # around it, no second span) can be evaluated straight to its real
    # JSON::Any type (bool/int/float/array/hash) via Crinja's own
    # `evaluate_value!` instead of going through VarSubstitutor#substitute
    # (always returns a String) and then re-parsing - which only ever
    # attempted JSON.parse for a result starting with '{' or '[', silently
    # leaving a scalar bool/int/float as its Python-repr-style STRING
    # ("True"/"False", from Crinja's own str(bool) rendering) instead of a
    # real JSON::Any bool. Found via robertdebock.tomcat's own `import_role:
    # name: robertdebock.service` vars: (`enabled: "{{ instance.
    # service_enabled | default(tomcat_service_enabled) }}"` - a real bool
    # default, filter chain and all) - `item.enabled is boolean` failed the
    # included role's own assert.yml because "enabled" was landing as the
    # STRING "True", same bug class as the well-documented Python-repr-list
    # one (apt.cr/package.cr/pip.cr/find.cr), just for a scalar bool here.
    # `render_include_role_vars`/`render_task_vars` had the identical
    # narrow-heuristic gap; shared here so both get the fix in one place.
    # Falls back to nil (caller does its usual String-based rendering) for
    # anything Crinja can't evaluate this way, or that isn't a single bare
    # span to begin with.
    private def evaluate_bare_mustache_preserving_type(raw : String, vars_context : Hash(String, JSON::Any)) : JSON::Any?
      stripped = raw.strip
      return nil unless stripped.starts_with?("{{") && stripped.ends_with?("}}")

      inner = stripped[2..-3]
      return nil if inner.includes?("{{") || inner.includes?("}}")

      VariableSubstitutor::JinjaRenderer.evaluate_structured(
        inner.strip, vars_context, strict: true
      )
    rescue
      nil
    end

    # Merge a task result's `ansible_facts` (if any) into the host's fact
    # store, the same generic mechanism gather_facts_for_all_hosts already
    # uses for the "facts" plugin's result - set_fact (and anything else
    # that returns ansible_facts) rides this without any special-casing.
    # `high_precedence` (true only for set_fact - see the @set_facts
    # ivar comment) additionally mirrors the write into @set_facts, the
    # subset build_vars_context applies at the very top of the ladder;
    # everything else in @facts is filled in at the low "host facts"
    # tier instead, below play vars - matching Ansible's own
    # precedence for the two cases instead of treating every
    # ansible_facts-returning module like set_fact.
    private def resolve_first_found(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      candidates = task.loop_first_found
      return nil unless candidates

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

      candidates.each do |raw|
        # SCALAR string form (`with_first_found: "{{ undefined_var }}"`):
        # strict - round174 matrix scenario 5b: the keyword's own value is
        # one bare template reference, Ansible templates it strictly
        # and fails the task ("'undefined_var' is undefined"), not silently
        # skip. Only a BARE/dotted `{{ }}` span raises (see
        # VarSubstitutor#raise_if_strict_undefined) - an ordinary literal
        # candidate string (no templating at all, the overwhelming common
        # case) or one with a filter chain is unaffected.
        #
        # LIST/dict form: lenient (strict omitted). Verified live against
        # ansible-core 2.19.4 (pluggero.upgrade round 601548): Ansible
        # hands a literal list's candidate strings to the first_found
        # lookup plugin, which templates each term itself with undefined
        # references rendering to nothing - so `{{ ansible_lsb.id }}` on a
        # host without lsb_release (the fact is absent, and even an
        # explicitly-defined empty dict's missing key behaves the same)
        # makes the candidate simply never match, and ALL candidates
        # missing surfaces as the clean "No file was found when using
        # first_found." exhaustion error - NOT an "object of type 'dict'
        # has no attribute 'id'" attribute exception. The old blanket
        # strict: true turned that into a hard template error on the
        # candidate, one divergence per unsupported-OS role.
        candidate = substitutor.substitute(raw, strict: task.loop_first_found_string_form?).strip
        next if candidate.empty?
        # A leftover {{ }} means the fact it depends on is missing;
        # treating that as a filename would only produce a confusing
        # "no such file", so skip the candidate instead.
        next if candidate.includes?("{{")

        if found = resolve_first_found_path(task, candidate, substitutor)
          return [JSON::Any.new(found)]
        end
      end

      # No candidate matched. `skip: true` (parsed into
      # task.loop_first_found_skip) is the only thing that makes
      # Ansible tolerate a miss - it returns [] so callers skip. Without
      # skip:, Ansible's first_found lookup RAISES and the task
      # FAILS ("The lookup plugin 'first_found' failed: No file was found
      # when using first_found.") - for ANY module the with_first_found:
      # keyword form is attached to, not just include_vars: (verified
      # live against ansible-core 2.19.4: ccdc.cpp_gui_dev_tools's own
      # include_tasks: + with_first_found: over "{{ ansible_distribution
      # }}.yml"-style candidates on an OS with no matching tasks/<OS>.yml
      # hard-fails the include task, it does not skip it). The old
      # skip-regardless-of-skip: behavior here was the one remaining
      # call-site gap - execute_include_vars already failed this shape
      # correctly (robertdebock.release, Rocky 9.6). FirstFoundLookupError
      # already flows through resolve_loop_items_or_raise (converted to
      # WhenEvaluationError -> clean task failure) for the general loop
      # and include_tasks paths; execute_include_vars rescues it directly.
      # LoopLookupError (not FirstFoundLookupError): the with_first_found:
      # keyword's exhaustion is the with_<lookup>: machinery's own lookup
      # failure - real prints the bodyless [ERROR] block (Origin: <unknown>
      # + invoke_lookup()) and a msg-only fatal for it on EVERY module
      # kind the keyword is attached to (module task, include_tasks:,
      # include_vars:, handler - live-verified vs 2.19.11, issue #12), not
      # the arg-finalization "Task failed:" wrapper the plain
      # FirstFoundLookupError conversion produced.
      raise LoopLookupError.new(
        "The lookup plugin 'first_found' failed: No file was found when using first_found."
      ) unless task.loop_first_found_skip?
      [] of JSON::Any
    end

    # with_first_found: and include_vars: resolve relative paths against
    # *different* directories, so the ROLE-relative directory priority is
    # CONTEXT-AWARE here rather than one fixed list. Real first_found
    # (ansible-core 2.19.11) picks its search subdir from the task's own
    # action name - first_found.py scans ['template', 'var', 'file'] against
    # the enclosing task's action, pluralizes it, and resolves every
    # candidate via DataLoader#path_dwim_relative_stack, which tries
    # <stack-entry>/<subdir>/<needle> before <stack-entry>/<needle> for each
    # entry of the task's search stack. Probed live 2026-10-10 with a probe
    # role holding the same basename under files/, tasks/, vars/ and
    # templates/ (round 5410000):
    #
    # - an include_vars: task (its action contains "var" -> subdir "vars")
    #   resolves its candidates from the role's vars/ FIRST - dochang.
    #   lsbrelease's "include os specific variables" (include_vars: +
    #   with_first_found: paths: [install]) resolves to vars/install/
    #   default.yml, while krikri anchored the custom paths: at the
    #   including file's dir unconditionally and picked the tasks/install/
    #   default.yml copy - which exists in that role too - merged zero
    #   variables, and the later package task died with
    #   "'lsbrelease_package' is undefined";
    # - every other context (debug, include_tasks, template, ... -> subdir
    #   "files") resolves files/ first: files/ won with all four subdirs
    #   populated, and tasks/ won over vars/ once files/ was removed.
    #
    # first_found_context_dirs below holds the concrete per-context dir
    # order.
    #
    # Also searches the ROLE ROOT itself (`task.role_path`), not just
    # its files/templates/vars subdirs directly - geerlingguy.mysql's
    # own "Include OS-specific variables." bakes the `vars/` prefix into
    # each candidate itself (`with_first_found: files:
    # ["vars/{{ansible_facts.os_family}}.yml"]`), unlike dev-sec
    # os_hardening's bare-filename style above. Without the role root as
    # a search root, "vars/Debian.yml" only ever got joined against
    # role_vars_dir (producing a nonexistent doubled "vars/vars/
    # Debian.yml"), so this always silently resolved to zero candidates
    # (`skip: true` on the with_first_found meant it skipped rather than
    # failed) and every var the role expected from that file - including
    # mysql_daemon - stayed undefined for the rest of the run.
    private def resolve_first_found_path(task : Task, candidate : String, substitutor : VarSubstitutor) : String?
      # Ansible normpath/unfrackpaths the found path before it becomes the
      # loop item, so `{{ playbook_dir }}/vars/../vars/Debian.yml` is
      # reported (and handed to include_vars:) as `.../vars/Debian.yml`.
      return File.exists?(candidate) ? Path.new(candidate).normalize.to_s : nil if candidate.starts_with?("/")

      # An explicit paths: sub-key (the dict form's own `- files: [...]
      # paths: [...]`) names the ONLY directories Ansible searches -
      # found via arillso.authorized_key's own `paths: ['distribution']`,
      # a custom, non-standard directory name outside the hardcoded roots
      # below. A relative entry resolves against the role root (Ansible's own behavior for with_first_found:'s paths:), an
      # absolute one passes through unchanged.
      #
      # Each custom path is templated first - `paths: ['{{ role_path }}/
      # vars']` is a very common idiom (andrewrothstein.kubic/.gpg among
      # others), and without rendering it, the raw literal string
      # "{{ role_path }}/vars" doesn't start with "/" so it fell into the
      # relative branch and got joined onto task.role_path AGAIN,
      # producing a garbage path with literal "{{"/"}}" in it that can
      # never exist. Every candidate then missed and `skip: true` turned
      # that into a silent skip instead of a visible failure - found
      # benchmarking andrewrothstein.buildah (round 152 3-way benchmark),
      # whose "Resolve platform specific vars" task always skipped,
      # leaving kubic_pkg_mgr undefined and silently omitting the whole
      # apt-key/apt-repo setup Ansible attempts.
      if custom_paths = task.loop_first_found_paths
        # A relative custom path anchors against the CONTEXT-AWARE
        # role-relative directory stack (first_found_context_dirs) plus
        # the role root itself. The historical single anchor order - the
        # including file's own directory first, then the role root - was
        # verified against ansible-core 2.19.4/2.19.12 for include_tasks:
        # tasks (`paths: ["distribution"]` on a with_first_found: task
        # living in a role's tasks/main.yml resolved to
        # roles/<role>/tasks/distribution/, not
        # roles/<role>/distribution/ - `included:
        # .../tasks/distribution/Linux.yml` in -vv output). Found via
        # three independent real roles hitting this identically
        # (sbaerlocher.powercfg/.onedrive/.domain-membership's own
        # "include distribution tasks" idiom) - `roots` below previously
        # only ever anchored a custom path at the ROLE ROOT, which is
        # what an earlier fix (andrewrothstein.buildah, round 152) was
        # actually verified against, but that role's own `paths:` entry
        # happened to be role-root-relative, not tasks-dir-relative -
        # the assumption that ALL custom paths: are role-root-relative
        # was never itself verified and turned out wrong. include_tasks:
        # keeps that pinned [including-file-dir, role-root] anchor pair
        # unchanged; the generic and include_vars: contexts go through
        # the context-aware stack instead (files/ first, vars/ first
        # respectively - the dochang.lsbrelease divergence above).
        including_file_dir = task.include_file_dir || task.role_path.try { |role_dir| File.join(role_dir, "tasks") }

        roots = custom_paths.flat_map do |path|
          rendered = substitutor.substitute(path).strip
          if rendered.starts_with?("/")
            [rendered]
          elsif task.include_tasks?
            [including_file_dir, task.role_path].compact.uniq!.map { |anchor| File.join(anchor, rendered) }
          else
            anchors = first_found_context_dirs(task)
            task.role_path.try { |role_dir| anchors << role_dir }
            anchors.uniq.map { |anchor| File.join(anchor, rendered) }
          end
        end
        return first_existing(roots, candidate)
      end

      roots = [] of String
      if task.include_tasks?
        task.include_file_dir.try { |dir| roots << dir }
        task.role_path.try { |role_dir| roots << File.join(role_dir, "tasks") }
      else
        first_found_context_dirs(task).each { |dir| roots << dir }
      end
      # vars//files//templates/ are NOT searched for an include_tasks:'
      # with_first_found: at all - include_tasks: consumes task-list YAML
      # only, and Ansible (verified live against ansible-core 2.19.x
      # with ccdc.ntp_configuration's "Set up NTP time synchronisation"
      # repro) skips straight past an "Debian.yml" candidate even when
      # vars/Debian.yml exists, resolving instead to tasks/Linux.yml.
      # Searching vars/ here matched the candidate against a vars MAPPING
      # and failed the task with "Included tasks file must be a YAML
      # list" - a vars file can never be a valid include target, so
      # including these subdirs for include_tasks: can only ever find a
      # file Ansible would never pick.
      task.role_path.try { |dir| roots << dir }
      roots << Dir.current

      first_existing(roots, candidate)
    end

    # The context-aware ROLE-relative directory order for with_first_found:
    # candidate resolution - used both by the no-paths: default stack above
    # and as the anchor stack for each relative custom paths: entry.
    #
    # include_vars: tasks search the role's vars/ first, then files/, then
    # tasks/: vars/-first is verified live twice (dochang.lsbrelease,
    # round 5410000, and mircomasa.filebeat round 812001 - both resolve the
    # vars/ copy when tasks/ holds the same basename; in the filebeat shape
    # the tasks/ copy is a task LIST, so picking it merged zero variables
    # and every later default that referenced one of them - fb_home:
    # '{{ default["fb_home"] }}' - failed with "'default[...]' is
    # undefined" even though the include_vars: task itself had reported
    # ok). The tasks/ fallback stays because so5.ssh_hostbased_auth and
    # so5.pbspro (both verified live against ansible-core 2.19.x)
    # include_vars: with_first_found: a "setup-<OS>.yml" idiom whose only
    # matching file lives under tasks/ (never vars/ or files/) - Ansible
    # resolved to tasks/setup-Debian.yml there.
    #
    # Every other context searches files/ first, then tasks/, then vars/
    # (the round-5410000 probe role: files/ won with all four subdirs
    # populated, tasks/ won over vars/ once files/ was removed).
    # templates/ keeps its historical slot between tasks/ and vars/. The
    # include_tasks: carve-out (no role subdirs at all - a vars file can
    # never be a valid include target) does NOT go through this helper.
    private def first_found_context_dirs(task : Task) : Array(String)
      dirs = [] of String
      if task.include_vars?
        # vars/ > tasks/ ONLY - the delegate's own cascade probe (vars/
        # removed, candidate in both files/ and tasks/) watched real pick
        # tasks/: real's include_vars context never searches files/.
        task.role_vars_dir.try { |dir| dirs << dir }
      else
        task.role_files_dir.try { |dir| dirs << dir }
      end
      task.include_file_dir.try { |dir| dirs << dir }
      task.role_path.try { |role_dir| dirs << File.join(role_dir, "tasks") }
      unless task.include_vars?
        task.role_templates_dir.try { |dir| dirs << dir }
        task.role_vars_dir.try { |dir| dirs << dir }
      end
      dirs.uniq
    end

    private def resolve_fileglob(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : Array(JSON::Any)?
      patterns = task.loop_fileglob
      return nil unless patterns

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      matches = [] of String

      patterns.each do |pattern|
        # strict: true - round174 matrix scenario 5a: `with_fileglob:
        # "{{ undefined_var }}"` must fail the task ("'undefined_var' is
        # undefined"), not silently glob nothing and skip. Only a BARE/
        # dotted `{{ }}` span raises (see VarSubstitutor#
        # raise_if_strict_undefined) - a literal pattern (no templating,
        # the common case) or a filter-chain pattern is unaffected.
        substituted = substitutor.substitute(pattern, strict: true)

        # `with_fileglob: "{{ some_list_var }}"` (a single templated
        # value that evaluates to a LIST of patterns, Ansible's own
        # idiom for e.g. cloudalchemy.prometheus's own
        # `prometheus_alert_rules_files: [prometheus/rules/*.rules]`) -
        # #substitute has no notion of the underlying value being a real
        # array, so it rendered the whole thing as the JSON-array TEXT
        # (`["prometheus/rules/*.rules"]`, literal brackets and quotes
        # included) and handed that straight to Dir.glob as one pattern -
        # its own bracket syntax means "character class", so an
        # unbalanced/malformed one (as this always was) raised
        # Regex::Error ("unterminated character set") instead of
        # matching real files. A real single-file glob pattern never
        # starts with "[" this way (that would mean "match one char from
        # this set" as the pattern's very first token, not a realistic
        # glob), so parsing it back as JSON here is safe.
        if substituted.starts_with?('[')
          parsed = (JSON.parse(substituted).as_a? rescue nil)
          if parsed
            parsed.each { |item| matches.concat(fileglob_matches(task, item.to_s)) }
            next
          end
        end

        matches.concat(fileglob_matches(task, substituted))
      end

      # Ansible does not sort fileglob results - glob.glob() hands back
      # readdir order, which differs per filesystem (reverse-alphabetical
      # on tmpfs, hash order on ext4), so krikri must not sort either or
      # item order diverges from real ansible-playbook output.
      matches.map { |path| JSON::Any.new(path) }
    end

    # Ansible's fileglob lookup plugin (2.19.11), per term:
    # - a pattern carrying a directory part dwims that dirname through
    #   find_file_in_search_path(variables, 'files', dirname) - the first
    #   EXISTING candidate from the task's search stack in
    #   path_dwim_relative_stack's candidate order (NeedleLookup's, whose
    #   message list was live-verified against 2.19.11) - and globs the
    #   basename under that one dir. clouddrove.ansible_role_docker_nginx
    #   (round 5210000) is the shape this covers: `with_fileglob:
    #   ../templates/config/site.d/*.*` inside the role's tasks/ dir
    #   matched the role's own templates as `<tasks>/../templates/...`
    #   in real, while krikri left the pattern cwd-relative, globbed
    #   nothing and skipped every config-transfer task - so nginx ran
    #   without its config and the role's wait_for timed out at 305s
    #   where real had already failed the role on an undefined var.
    # - a bare pattern (no "/" in it) tries `<p>/files` then `<p>` for
    #   each search-stack path p, and the FIRST path whose glob yields an
    #   isfile match wins (the plugin breaks out of its found_paths loop
    #   on the first hit) - the role's files/ dir still wins what it has,
    #   but a role without one now falls through to the role root and
    #   the task file's own dir like real, not to the process cwd.
    # An absolute pattern keeps passing through untouched. Non-file glob
    # results are filtered (the plugin's os.path.isfile check).
    private def fileglob_matches(task : Task, pattern : String) : Array(String)
      if pattern.starts_with?('/')
        # find_file_in_search_path warns for a missing dirname even
        # when the term is absolute (criecm.openldap, #349).
        warn_fileglob_dir_missing(File.dirname(pattern)) unless Dir.exists?(File.dirname(pattern))
        return Dir.glob(pattern).select { |path| File.file?(path) }
      end

      term_file = File.basename(pattern)
      found_paths = [] of String
      dirname = File.dirname(pattern)
      if dirname != "."
        stack = Krikri::NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task))
        basedir = if source_file = task.source_file
                    File.dirname(File.expand_path(source_file))
                  else
                    Dir.current
                  end
        candidates = Krikri::NeedleLookup.candidates(stack, basedir, "files", dirname)
        # find_file_in_search_path returns the first existing candidate,
        # or nil (with only a stderr warning) when none exists - the
        # loop then yields no items, exactly like real's `if dwimmed_path`
        # guard.
        if found = candidates.find { |candidate| Dir.exists?(candidate) }
          found_paths << found
        else
          warn_fileglob_dir_missing(dirname)
        end
      else
        Krikri::NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)).each do |path|
          found_paths << File.join(path, "files")
          found_paths << path
        end
      end

      found_paths.each do |dir|
        matches = Dir.glob(File.join(dir, term_file)).select { |path| File.file?(path) }
        return matches unless matches.empty?
      end
      [] of String
    end

    private def warn_fileglob_dir_missing(dirname : String) : Nil
      ResultDisplay.emit_display_warning(
        "Unable to find '#{dirname}' in expected paths (use -vvvvv to see paths)"
      )
    end

    # Resolve with_file: entries (if any) - Ansible's `file` lookup
    # plugin, reading each LISTED file's CONTENT (unlike with_fileglob,
    # which matches filenames by pattern) and binding it to `item`. A
    # relative entry is searched under the current role's own files/
    # dir, same convention lookup('file', ...)/copy:/template: already
    # use (ExpressionEvaluator#resolve_lookup_path). Entirely
    # unimplemented before - `item` never got bound at all, failing
    # with "'item' is undefined" regardless of whether the file existed.
    # Found via juju4.adduser's own `with_file: "{{ adduser_public_keys
    # }}"` (a templated single value resolving to a real list, e.g.
    # `[dummykey.pub]` - the common with_fileglob idiom too, so this
    # mirrors that method's own "{{ }} resolves to a JSON array text}"
    # handling).
    private def resolve_template_value(template : String, vars_context : Hash(String, JSON::Any)) : JSON::Any?
      match = template.strip.match(/\A\{\{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\}\}\z/)
      return nil unless match

      parts = match[1].split(".")
      current = vars_context[parts[0]]?
      parts[1..].each do |part|
        break unless current
        current = current.as_h?.try(&.[part]?)
      end

      # Audit pass (2026-08-11), a 10th copy of the recursive-re-
      # templating gap found alongside deep_render_item's own fix: a
      # loop: source itself (`loop: "{{ templated_default }}"`) whose
      # raw value is itself unrendered Jinja (a role default computed
      # from another default) was returned as-is - the caller's own
      # `value.as_a?`/`value.as_h?` checks then always failed against
      # the literal "{{ ... }}" text, so the loop silently resolved to
      # no items at all.
      #
      # Structural re-render (evaluate_bare_mustache_preserving_type),
      # not ExpressionEvaluator#evaluate + JSON.parse: the old string
      # path returned a container the same way `{{ container_var }}`
      # renders for DISPLAY - Crinja's own Python-repr Finalizer text
      # (single-quoted, e.g. `[{'type': 'deb', ...}]`) - which JSON.parse
      # then always failed to parse (invalid JSON), falling back to
      # wrapping the whole repr STRING as the "resolved" value. A
      # loop: source that's a ternary selecting between two role-default
      # LISTS (`percona_client_repositories: "{{ list_8 if version ==
      # '8.0' else list_5 }}"`, Oefenweb.percona_client's own vars/
      # main.yml) therefore always failed downstream with "The `loop`
      # value must resolve to a 'list', not 'str'" - Ansible
      # resolves the ternary to the actual list and iterates it fine.
      if current && (raw = current.raw).is_a?(String) && (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")) &&
         !VarSubstitutor.unsafe_root?(vars_context, template) && !UnsafeValues.unsafe_text?(raw)
        # ansible compiles the variable's value when the loop source reads
        # it, and a `{% do %}` tag there is a hard syntax error (issue #322).
        if (do_error = Krikri::TemplateDoTagScanner.do_tag_error(raw))
          raise VariableSubstitutor::TemplateSyntaxError.new("Syntax error in template: #{do_error}")
        end
        # A raw value that's a PURE block-tag expression (`{%- if ... -%}
        # ruby {%- else -%} ruby2.0 {%- endif -%}`, no `{{` at all) needs
        # the full Crinja renderer, same as every other "{{ OR {% OR {#"
        # re-render check in this codebase (see retemplated_lookup_
        # value's identical branch) - the plain ExpressionEvaluator only
        # understands `{{ }}` expressions. Found via diodonfrost.
        # amazon_codedeploy's own `package_requirements: '{%- if ... -%}
        # ruby {%- else -%} ruby2.0 {%- endif -%}'` fed to `with_items:
        # "{{ package_requirements }}"` - the old `raw.includes?("{{")`
        # check was false (no literal "{{" anywhere in the block-tag
        # text), so this whole re-render branch was skipped and the RAW
        # unrendered block-tag string was returned as the loop source,
        # failing downstream with "The `loop` value must resolve to a
        # 'list', not 'str'" instead of the single-item list
        # Ansible produces from with_items:'s own scalar-wrapping.
        if raw.includes?("{%") || raw.includes?("{#")
          rendered = VariableSubstitutor::JinjaRenderer.new(vars_context).render(raw)
          current = Krikri.parse_json_or_python_literal(rendered)
        else
          current = evaluate_bare_mustache_preserving_type(raw, vars_context) || begin
            inner = raw.strip
            if inner.starts_with?("{{") && inner.ends_with?("}}") && inner.scan("{{").size == 1
              # Strict, like ansible's own loop-source templating: an undefined
              # name inside the expression (`[user_name] + extra_list`) fails the
              # task with "'user_name' is undefined" - the lenient evaluator
              # turned it into a None item and the task ran (issue #210).
              rendered = VarSubstitutor.new(vars: vars_context).substitute(raw.strip, strict: true)
              Krikri.parse_json_or_python_literal(rendered)
            else
              # MIXED literal-plus-expression text (`mixed: "a-{{
              # lookup('env', 'HOME') }}-b"`, relayed via
              # `with_items: "{{ mixed }}"`): stripping the outer braces
              # of such a value's FIRST and LAST span and evaluating the
              # leftovers as ONE expression turned "a-{{ x }}-b" into the
              # garbage fragment "a- x -b" (live-verified against
              # ansible-playbook 2.19.11, which iterates the RENDERED
              # string `a-/home/labros-b` as the single item - this
              # engine produced the literal "undefined" sentinel instead)
              # - a two-span value like "a-{{ x }}-b-{{ y }}" mangles the
              # same way even though a single {{ }} wrapper "protects" a
              # one-span value. Render through the full substitute path
              # (the same templating task params get) so literal text is
              # kept and every embedded span evaluates.
              rendered = VarSubstitutor.new(vars: vars_context).substitute(inner, strict: true)
              Krikri.parse_json_or_python_literal(rendered)
            end
          end
        end
      end

      # current can be `nil` two ways: the top-level var (parts[0]) is
      # missing from vars_context entirely, OR it IS present but a later
      # dotted segment (`some_dict.missing_key`) isn't. Both are
      # "undefined" for strictness purposes. An EXPLICITLY-set `null`
      # value (`vars_context[parts[0]]?` returning a JSON::Any wrapping
      # Nil, not Crystal nil) does NOT hit this branch - see bump-2's
      # list-type check in resolve_loop_template for what Ansible
      # does with a defined-but-null loop source instead.
      raise UndefinedVariableError.new(Krikri.strict_undefined_message(match[1], vars_context)) if current.nil?

      current
    end

    # Evaluates task.when_condition (if any) against vars_context, printing
    # "skipping: [...]" and bumping the skipped counter when it's false -
    # shared by execute_task_once and the batch-group trigger path
    # (execute_batch_group) so both interpret when: identically.
    #
    # `defer_stats`: when true (a loop item), the skipped counter is NOT
    # bumped here. Ansible counts a looped task once in the recap, not
    # once per skipped item - loop-aggregation happens once in
    # finish_looped_task, so a loop that ends up with zero executed items is
    # recorded as a single "skipped". Deferring avoids per-item skipped
    # inflation (a 5-item all-skipped loop must be skipped=1, not skipped=5).
    # Raised by `when_passes?` when evaluating a `when:` condition itself
    # raises (e.g. `mounts | selectattr(...) | first` on an empty match -
    # FilterEngine's own `first`/`last` raise "No first item, sequence
    # was empty." rather than silently returning nil, matching real
    # Jinja2's `do_first`). This used to crash the ENTIRE process with an
    # unhandled-exception stack trace - `when_passes?` has 7 call sites
    # across solo/looped/batched task execution and `meta:`, none of
    # which caught it. Ansible degrades to one clean failed task
    # ("Task failed: Error while evaluating conditional: ...") and
    # continues the run, not a crash.
    #
    # `when_passes?` itself raises rather than swallowing so each call
    # site can decide how to represent the failure in ITS OWN result
    # shape - a solo/looped task (`execute_task_once`,
    # `execute_looped_task_batched`) can turn this into a real `failed:
    # true` result that flows through the exact same
    # `finish_single_task`/`finish_looped_task` aggregation a normal
    # task failure does (so a looped `when:` failure correctly shows
    # `failed=1`, not `skipped=1`, in the recap - matching
    # Ansible's own "One or more items failed"); a bare `meta:`/
    # `include_vars:`/batch-group-member check that has no such result
    # pipeline falls back to `swallow_when_error`, which replicates
    # exactly what this method used to do inline (stats/halt/register/
    # print, respecting `ignore_errors:`) and returns `false` - reusing
    # the same "don't run this task" signal every caller already treats
    # a when:-skip as.
    class WhenEvaluationError < Exception
    end

    # A `loop:` source that IS defined but resolves to a non-list (a
    # null, a scalar string, a dict, ...). Unlike the UNDEFINED case
    # (whose verdict consults the task's own when:, see
    # resolve_loop_items_or_raise), real 2.19.11 fails the task at
    # task-keyword finalization - BEFORE any when: ever evaluates - so
    # no when: shields it (live-verified vs 2.19.11: `when: false` plus
    # a defined-null `loop: "{{ nullv }}"` prints the [ERROR] type-error
    # block + one failed task, where the same when: skips an undefined
    # source; round 5410000 badsectorlabs.ludus_vulhub). Carries no
    # "Task failed: " prefix of its own - real's registered fatal msg is
    # the bare wording ("The `loop` value must resolve to a 'list', not
    # 'NoneType'.") - and gets its own [ERROR] block (
    # emit_loop_source_error_block) whose Origin points at the loop
    # keyword's VALUE token plus a fixed "Provide a list..." tail line,
    # not at the task name like the conditional-evaluation chain.
    class LoopTypeError < WhenEvaluationError
    end

    # A `with_<lookup>:` source whose resolved TERM is of the wrong type
    # for the lookup (a `with_dict:` over a null/scalar). Real fails the
    # task with the lookup plugin's own type refusal ("The lookup plugin
    # 'dict' failed: ... expects a dictionary, got 'None' of type <class
    # 'NoneType'>)"), a BARE registered msg (no "Task failed:" prefix -
    # live-verified vs 2.19.11) and a bodyless [ERROR] block whose Origin
    # is `<unknown>` plus a fixed "invoke_lookup()" line - the
    # lookup-invocation site never carries source positions. See
    # emit_loop_source_error_block for the block.
    class LoopLookupError < WhenEvaluationError
      # true when the failing lookup ran INSIDE the loop source's own
      # template (`loop: "{{ query('first_found', ...) }}"`) - ansible-core
      # pins those errors' Origin at the loop keyword's VALUE token
      # (live-verified vs 2.19.11, issue #12). false keeps the with_<lookup>:
      # keyword machinery's bodyless shape - that invocation site carries
      # no source position, so real prints `Origin: <unknown>` plus the
      # bare `invoke_lookup()` frame line. See
      # emit_loop_source_error_block for both blocks.
      getter? origin_known : Bool

      def initialize(message : String, @origin_known = false)
        super(message)
      end
    end

    # Shared substitute+evaluate+strict-undefined-rescue sequence for a
    # when: condition - the one place that owns `raise_undefined: true`
    # (Ansible's strict-undefined case for when:, see
    # ConditionalEvaluator::UndefinedVariableError) so that adding a new
    # strict call site is structurally impossible without also getting
    # this rescue: any raise here (the strict undefined case, or any
    # other - e.g. FilterEngine's `first`/`last` on an empty sequence)
    # is converted into a WhenEvaluationError, which EVERY caller below
    # rescues into a clean failed result for the affected host/item -
    # never left to propagate uncaught (that crashed the whole process
    # before 40671ba).
    private def resolve_task_check_mode(task : Task, vars_context : Hash(String, JSON::Any)? = nil) : Bool
      if (expr = task.check_mode_expr) && (vars = vars_context)
        substitutor = VarSubstitutor.new(vars: vars)
        rendered = substitutor.substitute(expr)
        begin
          return ConditionalEvaluator.evaluate(rendered, {} of String => JSON::Any)
        rescue
          return @check_mode
        end
      end

      value = task.check_mode?
      value.nil? ? @check_mode : value
    end

    # Runtime resolution of a task's effective become: value. Mirrors
    # ansible-core's TaskExecutor._set_become_plugin: an `ansible_become`
    # var present in the task's vars context (inventory host vars
    # included) decides become OUTRIGHT - the keyword ladder is only the
    # fallback when the var is absent, so inventory
    # `ansible_become: true` escalates a `file:` task even without any
    # become: keyword (issue #3: the touched file came out owned by the
    # login user instead of root). The var's value goes through the same
    # boolean coercion ansible's boolean() applies; a value it can't
    # interpret falls back to the keyword path instead of erroring (the
    # lenient-degradation rule this codebase already applies to templated
    # connection vars).
    private def resolve_task_become(task : Task, substitutor : VarSubstitutor) : Bool
      if raw = substitutor.vars["ansible_become"]?
        decided = ansible_become_var_boolean(raw, substitutor)
        return decided unless decided.nil?
      end

      expr = task.become_expr
      return task.become? unless expr

      # Ansible converts the rendered keyword with the same strict boolean()
      # it applies to any bool keyword, so a templated name such as
      # `become: "{{ ansible_user_id }}"` fails the task instead of being
      # read as a condition (issue #143). The TEMPLATE itself is strict
      # too: ansible-core 2.19 fails the task on an undefined reference
      # inside a keyword before any boolean conversion happens ("Task
      # failed: Error processing keyword 'become': 'ansible_user_id' is
      # undefined", with gather_facts: false the var never becomes a
      # gathered fact) - the lenient render used to produce the
      # "undefined" sentinel and fail later with the wrong
      # could-not-convert wording (issue #159).
      rendered = begin
        substitutor.substitute(expr, strict: true)
      rescue e : UndefinedVariableError
        raise UndefinedVariableError.new("Task failed: Error processing keyword 'become': #{e.message}")
      end
      decided = ansible_become_string_boolean(rendered)
      return decided unless decided.nil?
      # KeywordBooleanError (not a plain message) so the failure result
      # can render Ansible's own three-link chain with each link Origin'd
      # at its own source position - see become_conversion_failure_json.
      raise KeywordBooleanError.new("become", rendered)
    end

    # The effective become_user, with the same var-over-keyword origin
    # order the become plugin's options resolve under (ansible's config
    # manager: direct > vars > keyword): an `ansible_become_user` var in
    # the task's vars context outranks a task-level `become_user:`
    # keyword, which falls back to nil (the caller defaults to "root").
    private def resolve_task_become_user(task : Task, vars_context : Hash(String, JSON::Any), substitutor : VarSubstitutor) : String?
      if raw = vars_context["ansible_become_user"]?
        if user = ansible_become_var_string(raw, substitutor)
          return user
        end
      end
      # The become_user KEYWORD strict-fails on an undefined variable like
      # any other templated task keyword in ansible-core 2.19 ("Task
      # failed: Error processing keyword 'become_user': 'x' is undefined")
      # - the lenient substitution here used to render "undefined" and run
      # `sudo -u undefined` instead of failing the task (issue #31). The
      # ansible_become_user var path above stays lenient: that is a plain
      # variable, not keyword templating, and its lenient degradation is
      # the rule the become-var tests rely on.
      task.become_user.try do |raw_user|
        begin
          substitutor.substitute(raw_user, strict: true)
        rescue e : UndefinedVariableError
          raise UndefinedVariableError.new("Task failed: Error processing keyword 'become_user': #{e.message}")
        end
      end
    end

    # ansible boolean()'s accepted forms (convert_bool.BOOLEANS_TRUE /
    # BOOLEANS_FALSE), case-insensitive; nil for anything else so the
    # caller falls back to the keyword ladder instead of guessing.
    private def ansible_become_var_boolean(raw : JSON::Any, substitutor : VarSubstitutor) : Bool?
      value = raw.raw
      value = substitutor.substitute(value) if value.is_a?(String) && (value.includes?("{{") || value.includes?("{%"))
      return value if value.is_a?(Bool)
      return value != 0 if value.is_a?(Int)
      return nil unless value.is_a?(String)
      ansible_become_string_boolean(value)
    end

    # The string forms of ansible's boolean() (case-insensitive, surrounding
    # whitespace ignored); nil for anything else, which callers turn into
    # their own failure rather than a guessed value.
    private def ansible_become_string_boolean(value : String) : Bool?
      case value.strip.downcase
      when "y", "yes", "on", "1", "true"  then true
      when "n", "no", "off", "0", "false" then false
      end
    end

    private def ansible_become_var_string(raw : JSON::Any, substitutor : VarSubstitutor) : String?
      value = raw.raw
      return nil unless value.is_a?(String)
      return nil if value.empty?
      rendered = substitutor.substitute(value)
      return nil if rendered.empty?
      rendered
    end

    # Runtime resolution of a templated `ignore_errors:` (Task#
    # ignore_errors_expr, parsed alongside the eager fallback guess in
    # PlaybookParser.parse_ignore_errors). Mirrors resolve_task_check_mode
    # above: the parse-time guess defaults templated values to TRUE,
    # which is exactly backwards for the idiom's dominant real-world form
    # `ignore_errors: "{{ ansible_check_mode }}"` (= ignore only in check
    # mode) - on a normal run every failure on such a task was silently
    # ignored, the host never halted, and the play kept running where
    # Ansible had already stopped it (dj-wasabi.telegraf, round
    # 76017: the correctly-failed telegraf=1.18.2-1 apt install got
    # "...ignoring"-ed and the divergence only surfaced two tasks later).
    #
    # *vars_context* is the same live context every execution path
    # already carries (ansible_check_mode is bound in it - see
    # build_vars_context); callers without one in scope (controller-side
    # failure helpers, batch-step construction, display-only paths) pass
    # nil and get a minimal context carrying just ansible_check_mode,
    # which is all the dominant idiom needs - an arbitrary-var template
    # that can't resolve falls back to the parse-time guess, no worse
    # than before this existed.
    private def resolve_task_ignore_errors(task : Task, vars_context : Hash(String, JSON::Any)? = nil, host : Host? = nil) : Bool
      expr = task.ignore_errors_expr
      return task.ignore_errors? unless expr

      # A caller with no vars_context in hand but a host (halt_if_failed,
      # swallow_when_error, the include/validate failure bookers) must
      # still evaluate against the TASK'S REAL scope: the old
      # ansible_check_mode-only fallback rendered any expression touching
      # a real variable to the "undefined" sentinel and fell back to
      # parse_ignore_errors' default-to-true guess - so
      # `ignore_errors: "{{ ignore_erros|default(False) }}"` (a
      # parse-time-true guess, real value False) silently IGNORED the
      # block's failure and kept executing tasks on a host Ansible had
      # already halted (exphost.create_user's block, round 5250000).
      vars = vars_context || (host ? build_vars_context(task, host) : {"ansible_check_mode" => JSON::Any.new(@check_mode)} of String => JSON::Any)
      substitutor = VarSubstitutor.new(vars: vars)
      rendered = substitutor.substitute(expr)
      # A reference the given *vars* can't resolve (an expression
      # touching more than the minimal ansible_check_mode-only fallback
      # some call sites pass) renders as the lenient-substitution
      # sentinel "undefined" - a bare identifier ConditionalEvaluator
      # itself does NOT raise on, it evaluates falsy, so the `rescue`
      # below is NOT the safety net a first read suggests: it only
      # catches a genuine parse error, never this shape. Caught
      # explicitly instead, falling back to the parse-time guess rather
      # than trusting an evaluation that was never really about the
      # task's own expression at all.
      return task.ignore_errors? if rendered == "undefined"
      ConditionalEvaluator.evaluate(rendered, vars) rescue task.ignore_errors?
    end

    # Runtime resolution of a templated `no_log:` (Task#no_log_expr).
    # Same shape as resolve_task_ignore_errors above: the parse-time
    # guess (parse_become_value) defaults ANY templated value to true -
    # the safe direction for this SECURITY control (never under-hides a
    # real secret if resolution fails), but it means a task like
    # newrelic.newrelic-infra's own `no_log: "{{
    # nrinfragent_hide_config_values }}"` (defaulting false) has its
    # failure message suppressed on EVERY run regardless of the actual
    # value - masking Ansible errors from anyone debugging a failure.
    #
    # SECURITY-CRITICAL: an unresolvable reference must fall back to the
    # safe (hide-it) guess, not to whatever a stray evaluation of the
    # literal sentinel "undefined" happens to produce - verified live
    # that ConditionalEvaluator.evaluate("undefined", ...) returns
    # `false` (would SHOW a secret) without raising at all, so the
    # `rescue` alone does not protect this the way it looks like it
    # does; the sentinel is checked for explicitly before ever reaching
    # the evaluator.
    private def resolve_task_no_log(task : Task, vars_context : Hash(String, JSON::Any)? = nil) : Bool
      expr = task.no_log_expr
      return task.no_log? unless expr

      vars = vars_context || {"ansible_check_mode" => JSON::Any.new(@check_mode)} of String => JSON::Any
      substitutor = VarSubstitutor.new(vars: vars)
      rendered = substitutor.substitute(expr)
      return task.no_log? if rendered == "undefined"
      ConditionalEvaluator.evaluate(rendered, vars) rescue task.no_log?
    end

    # ── issue #317: a templated no_log: whose variable is UNDEFINED ──
    #
    # ansible-core 2.19 strictly templates every task keyword before the
    # task itself runs; a `no_log: "{{ debug_hide }}"` whose variable is
    # undefined FAILS the task at that point ("Task failed: Error
    # processing keyword 'no_log': 'debug_hide' is undefined", rc 2)
    # after printing the "Invalid no_log value for task, output will be
    # masked" warning, with the result still shown censored. This probe
    # runs ONLY at the pre-execution keyword sites (execute_task_once,
    # prepare_batch_step, the handler funnel) where the task's real vars
    # context exists; resolve_task_no_log above deliberately keeps the
    # lenient safe-hide fallback everywhere else - its callers run after
    # a result already exists (too late to mirror Ansible's pre-module
    # failure), its minimal-fallback contexts cannot distinguish a
    # genuinely undefined name from a mere unresolved one, and every
    # other unresolvable shape must keep silently hiding rather than
    # inventing task failures.
    private def no_log_keyword_undefined_error(task : Task, vars_context : Hash(String, JSON::Any)) : String?
      expr = task.no_log_expr
      return nil unless expr
      substitutor = VarSubstitutor.new(vars: vars_context)
      begin
        # strict: is the become: keyword probe's own strictness boundary -
        # only a whole-value bare/chain reference raises, so a `| default()`
        # guard (and every operator/filter spelling) stays lenient and the
        # define-then-render behaviors above are untouched. The explicit nil
        # return keeps the successful render's VALUE from leaking out of the
        # probe as if it were an error message.
        substitutor.substitute(expr, strict: true)
        nil
        # Rescuers beyond the undefined class (a mandatory filter's
        # FilterPluginError, an expression-runtime RenderExpressionError, a
        # block-tag TemplateSyntaxError) keep the pre-existing lenient
        # continuation - real's keyword handling for those shapes was never
        # replicated here, and this fix only claims the plainly-undefined
        # wording Ansible 2.19 fails on.
      rescue e : UndefinedVariableError
        e.message
      rescue
        nil
      end
    end

    # The failed result for a templated no_log: whose variable is
    # undefined: the same collapsed brief as become's undefined keyword
    # (issue #159), plus the marker its display side needs for the
    # warning/keyword-error blocks and the changed-LESS censored fatal -
    # the keyword failure stops the task before any module ran, so unlike
    # a masked module failure there is no "changed" key to keep (seen
    # live, issue #317).
    private def no_log_keyword_failure_json(task : Task, undefined_msg : String) : JSON::Any
      result = JSON.parse({
        "changed" => false,
        "failed"  => true,
        "msg"     => "Task failed: Error processing keyword 'no_log': #{undefined_msg}",
      }.to_json)
      result.as_h["_ansible_no_log_keyword_failure"] = JSON.parse({
        "undefined" => undefined_msg,
        "origin"    => keyword_value_origin(task, "no_log"),
      }.to_json)
      result
    end

    # Whole-single-span set_fact values carry their NATIVE type
    # across the strings-only param wire: ansible-core 2.19's
    # templar keeps the expression's own type for a template whose
    # whole AST is one output node (a Jinja string expression stays
    # a str even when the text looks numeric - "{{ '8.9' }}" is the
    # string "8.9", NOT the float 8.9; only an expression that
    # actually evaluates to a number, e.g. "{{ 8.9 }}" or
    # "{{ '8.9' | float }}", is one). The substituted string alone
    # cannot express that ("8.9" from a string expression and from a
    # float expression are identical text), and the set_fact plugin's
    # legacy string-shape coercion - a leftover of pre-2.19
    # ANSIBLE_JINJA2_NATIVE=off literal_eval behavior, introduced
    # with the plugin itself in 0.9.24 - turned every numeric-looking
    # string fact into a number. pluggero.openssh (round 981024):
    # `openssh_installed_version != openssh_pkg_mgr_version` compared
    # a coerced float against the real string and was always true,
    # reinstalling openssh on every run. Evaluating the expression
    # structurally here - INSTEAD of, never in addition to, the string
    # substitution - (evaluate_structured = the engine's
    # real typed evaluation) recovers the type at the one point it
    # is still known; the prefix marks the value on the wire so the
    # set_fact plugin decodes it instead of re-coercing (see
    # NATIVE_TYPED_PREFIX). Guarded to exactly the shapes
    # Ansible native-types: a failed/unresolvable structured
    # evaluation (including a None result, which keeps the
    # NONE_SENTINEL flow in substitute_task_params) and the omit sentinel
    # fall back to the plain substitution; multi-span/mixed text and
    # block-tag values never enter this branch (whole_single_span),
    # matching Ansible's one-output-node rule.
    private def native_typed_value(substitutor : VarSubstitutor, stripped_value : String) : String?
      expr = stripped_value[2..-3].strip
      # evaluate_structured is lenient about undefined names
      # (`undefined_var['key'] | list` yields []), so the strict check
      # #substitute would have run happens here first - and raises.
      substitutor.check_strict_undefined(expr)
      native_value = begin
        # Strict-undefined-aware structured evaluation (see
        # VarSubstitutor#evaluate_structured_strict): a whole-span bool/
        # scalar result computed from a CONSUMED missing attribute
        # (`{{ d.missing == 'x' }}`, `{{ not d.missing }}`,
        # `{{ d.missing is none }}`, a ternary over one) must fail the
        # task like ansible-core 2.19, not finalize natively.
        substitutor.evaluate_structured_strict(expr)
      rescue
        nil
      end
      return nil unless native_value
      raw = native_value.raw
      # A None result (`{{ none }}`, or a var holding YAML `~`) IS kept
      # natively for set_fact: ansible-core sets the fact to Python
      # None (`is none` -> True), not to the empty string. Falling back to
      # the plain substitution here used to collapse the None into "" and
      # then into substitute_task_params's whole-span-None NONE_SENTINEL
      # marking, whose sentinel text leaked into the fact itself (the fact
      # became the literal string "__crystal_ansible_none__"). The wire
      # form is just JSON null - the set_fact plugin's prefix decode turns
      # it into a null fact value. (native_typed_value is only reached for
      # set_fact params - native_containers - so module params keep their
      # own explicit-None NONE_SENTINEL argspec flow untouched.)
      return Krikri::NATIVE_TYPED_PREFIX + "null" if raw.nil?
      return nil if raw.is_a?(String) && raw == OMIT_SENTINEL
      Krikri::NATIVE_TYPED_PREFIX + native_value.to_json
    end

    # The decoded JSON container behind a NATIVE_TYPED_PREFIX msg wire
    # value (parse_module_params's literal list/dict debug msg branch), or
    # nil for any other shape - an unprefixed value, an unparsable payload,
    # or a prefixed SCALAR (those keep the whole-span/native-typed flow
    # below).
    private def native_typed_msg_container(stripped_value : String) : JSON::Any?
      return nil unless stripped_value.starts_with?(Krikri::NATIVE_TYPED_PREFIX)
      parsed = begin
        JSON.parse(stripped_value[Krikri::NATIVE_TYPED_PREFIX.size..])
      rescue JSON::ParseException
        return nil
      end
      parsed.raw.is_a?(Array) || parsed.raw.is_a?(Hash) ? parsed : nil
    end

    # Renders a native-typed msg container's STRING leaves through the
    # substitutor (each list item is its own template in Ansible - mixed
    # text around a `{{ }}` span stays mixed text) and re-encodes the
    # NATIVE_TYPED_PREFIX wire; non-string leaves pass through natively.
    private def render_debug_msg_container(substitutor : VarSubstitutor, node : JSON::Any) : String
      Krikri::NATIVE_TYPED_PREFIX + render_debug_msg_leaves(substitutor, node).to_json
    end

    private def render_debug_msg_leaves(substitutor : VarSubstitutor, node : JSON::Any) : JSON::Any
      case raw = node.raw
      when String
        msg_leaf_rendered(substitutor, raw)
      when Array
        JSON::Any.new(raw.map { |item| render_debug_msg_leaves(substitutor, item) })
      when Hash
        rendered = Hash(String, JSON::Any).new
        raw.each { |k, v| rendered[k] = render_debug_msg_leaves(substitutor, v) }
        JSON::Any.new(rendered)
      else
        node
      end
    end

    # A list/dict msg leaf that is WHOLLY one `{{ expr }}` span keeps the
    # expression's structured value: real templates the msg container
    # element-by-element (the same per-leaf rule the text rendering here
    # follows) and a single-span element keeps its native type, so
    # `msg: ["{{ dict_var }}"]` shows a real dict (the same native-typing
    # bar the `var:` path and every structured set_fact leaf already pass)
    # - the old substitute-only leaf collapsed it to the quoted
    # JSON/repr text string. Undefined spans and mixed text fall back to
    # the strict substitute below, which owns exactly what real fails
    # with there ('missing' is undefined) and what renders as text.
    private def msg_leaf_rendered(substitutor : VarSubstitutor, raw : String) : JSON::Any
      stripped = raw.strip
      if stripped.starts_with?("{{") && stripped.ends_with?("}}") &&
         raw.split("{{").size == 2 && raw.split("}}").size == 2 &&
         (structured = VariableSubstitutor::Rerender.whole_span_structured(substitutor.vars, stripped))
        return structured
      end
      JSON::Any.new(substitutor.substitute(raw, strict: true, output: true))
    end

    # Whole-single-span template leaves of a JSON-container set_fact
    # param evaluate structurally (same semantics as #native_typed_value,
    # per leaf); any leaf that isn't a clean whole-single-span template,
    # or whose native evaluation yields omit, bails the whole param back
    # to the flat string substitution.
    private def native_typed_container_value(substitutor : VarSubstitutor, stripped_value : String) : String?
      return nil unless stripped_value.starts_with?('{') || stripped_value.starts_with?('[')
      parsed = begin
        JSON.parse(stripped_value)
      rescue JSON::ParseException
        return nil
      end
      typed = rewrite_native_json_leaves(substitutor, parsed)
      return nil unless typed
      Krikri::NATIVE_TYPED_PREFIX + typed.to_json
    end

    private def rewrite_native_json_leaves(substitutor : VarSubstitutor, node : JSON::Any) : JSON::Any?
      case raw = node.raw
      when String
        stripped = raw.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
          typed = native_typed_value(substitutor, stripped)
          return nil unless typed && typed.starts_with?(Krikri::NATIVE_TYPED_PREFIX)
          begin
            JSON.parse(typed[Krikri::NATIVE_TYPED_PREFIX.size..])
          rescue JSON::ParseException
            nil
          end
        elsif raw.includes?("{%") || raw.includes?("{#")
          nil
        elsif raw.includes?("{{")
          # Mixed text around a span (`"{{ cfg }}:/config"`) is a plain
          # string in Ansible and must not stop a sibling whole-span leaf
          # (`env: "{{ envv }}"`) from staying a native dict; bailing here
          # stringified that sibling into Python-repr text.
          rendered = substitutor.substitute(raw, strict: true, output: true)
          return nil if rendered.includes?(OMIT_SENTINEL)
          JSON::Any.new(rendered)
        else
          node
        end
      when Array
        items = [] of JSON::Any
        raw.each do |item|
          typed = rewrite_native_json_leaves(substitutor, item)
          return nil unless typed
          items << typed
        end
        JSON::Any.new(items)
      when Hash
        result = JSON::Any.new(Hash(String, JSON::Any).new)
        hash = result.as_h
        raw.each do |key, value|
          typed = rewrite_native_json_leaves(substitutor, value)
          return nil unless typed
          hash[key.to_s] = typed
        end
        result
      else
        node
      end
    end

    private def substitute_task_params(
      params : Hash(String, String),
      substitutor : VarSubstitutor,
      native_containers : Bool = false,
      module_name : String? = nil,
      task : Task? = nil,
    ) : Hash(String, String)
      result = Hash(String, String).new

      # ansible-core finalizes task args in alphabetical key order, so with
      # several undefined args the one named in the error is the first by
      # name (live-verified: get_url `checksum` before `url`, copy `dest`
      # before `src`). `result` is reordered to the original order below.
      params.keys.sort!.each do |key|
        value = params[key]
        # The `_jinja_block_args` raw string (see parse_module_params's
        # marker comment) must reach expand_templated_args UNRENDERED:
        # substituting it here would inline-render its `{% %}` blocks and
        # erase exactly the block-contribution shape the executor's
        # finalization failure needs to inspect.
        if key == "_jinja_block_args"
          result[key] = value
          next
        end
        # assert's `that:` is the one module argument Ansible does NOT
        # pre-render: its action plugin compiles each item as a raw
        # EXPRESSION (that's why `that: [a.b >= {{ x }}]` reaches
        # Ansible's "Template delimiters are not supported in
        # expressions" error instead of being rendered away first -
        # chriswayg.mailcow / rockandska.rabbitmq, rounds 1500413/
        # 1500208). Leaving it raw lets AssertActionPlugin run its own
        # delimiter rejection (ConditionalEvaluator.
        # template_delimiter_error) on text where the delimiters still
        # exist, then substitute per-item exactly as before - a bare
        # reference (no `{{ }}`) is untouched by this branch either way,
        # so the verified "Error while evaluating conditional: 'x' is
        # undefined" shape is unaffected.
        if module_name == "ansible.builtin.assert" && key == "that"
          result[key] = value
          next
        end
        # Dynamic variable names - `set_fact: "{{ item.key }}": "{{ item.value }}"`
        # - carry a template in the *key*, not just the value. Ansible
        # (and dev-sec os_hardening's "Set OS dependent variables", which
        # builds os_* vars exactly this way) substitutes the key too, so a
        # role can name facts from a loop item's fields. Substituting only
        # the value used to register the fact under the literal key
        # `{{ item.key }}`, making `{{ auditd_package }}` resolve undefined
        # in the next task.
        # strict: true - Ansible's module-arg templating is
        # strict-undefined by default and raises when a `{{ }}` span
        # references a genuinely undefined variable, failing the task
        # ("Finalization of task args ... failed"). See
        # UndefinedVariableError's own comment for the narrow, bare-
        # reference-only scope of what actually raises here.
        # output: a module argument is final text (see
        # VarSubstitutor#substitute), so a container inside MIXED text
        # renders the way Ansible renders one (Python repr,
        # live-verified: `msg: "pre {{ list }} post"` prints
        # "pre ['a', 'b'] post"). EXCEPT for a param whose ENTIRE value
        # is one bare `{{ }}` span: Ansible's native typing keeps
        # the referenced value's native type there (live-verified vs
        # ansible-playbook 2.19.11: `apt: name: "{{ pkg_list }}"` with a
        # real list var looks up the clean ELEMENTS - "No package
        # matching 'probe-pkg-one'" - never the repr text), so the
        # plugin wire carries the double-quoted JSON form this codebase
        # uses for containers everywhere else (set_fact's own
        # native_containers path, stringify_json_scalar). Rendering
        # whole-span containers as repr text instead forced every
        # list-param plugin to "repair" single-quoted repr back into a
        # real list - a repair that also swallowed values that merely
        # LOOK like a repr (a literal `name: "['a', 'b']"` string, or a
        # `{% if %}...{% else %}['a']{% endif %}` block's output - both
        # plain strings in Ansible, live-verified - the latter via
        # HanXHX.debian_bootstrap) into containers Ansible never
        # had.
        # set_fact (native_containers) keeps output:false for ALL its
        # params: Ansible keeps a set_fact: value NATIVELY typed -
        # a container expression stays a real dict/list, not display
        # text. Formatting it as output text here produced a
        # Python-repr STRING fact (buluma.ara_api's own
        # `ara_api_configuration: "{{ {ara_api_env: reconciled_configuration} }}"`
        # became the literal `{'default': {...}}` text, which its own
        # to_nice_yaml then quoted as a scalar and the app failed to
        # parse, round 190).
        stripped_value = value.strip
        # single_top_level_span? (not the naive scan count) so a nested
        # `'{{ var }}'` string literal inside the expression - the
        # double-templated lookup idiom, rhaamo.snmpd round 5460199 -
        # still counts as ONE whole span: the braces are quoted text,
        # and treating the param as mixed text cost it the native-typed
        # container on the plugin wire (apt got the Python-repr text
        # where ansible-core passes the real list).
        whole_single_span = VarSubstitutor.single_top_level_span?(stripped_value)
        # set_fact whole-single-span values are evaluated STRUCTURALLY, once,
        # to keep the expression's native type (see NATIVE_TYPED_PREFIX's
        # comment below). Evaluating first and skipping the string
        # substitution when it succeeds keeps side-effecting expressions
        # (`lookup('pipe', ...)`, now(), random) to exactly ONE run, like
        # Ansible - evaluating twice ran a pipe lookup twice and
        # stored the second run's output. Undefined/None/omit results fall
        # back to the plain substitution, which owns the strict-undefined
        # error and the NONE/OMIT sentinel flows.
        # While finalizing THIS param, register its (task, key) on the
        # current fiber so the evaluator can originate the "Jinja
        # constant strings should not contain embedded templates"
        # warning at the param's value position (issue #259) - ansible
        # inherits the templated value's Origin onto its embedded
        # lookup-arg constants, and the evaluator has no task context of
        # its own. Popping in the begin's ensure keeps the stack
        # consistent through the strict-undefined rescues too.
        VarSubstitutor.set_current_task_param(task.source_file, task.source_line, key) if task
        debug_msg = key == "msg" && module_name == "ansible.builtin.debug"
        begin
          # inside the begin: native_typed_value's strict-undefined check must
          # get the same "Error while resolving value for '<key>'" wrapper
          native_typed = if debug_msg && (msg_container = native_typed_msg_container(stripped_value))
                           # A parse-time literal list/dict msg (NATIVE_TYPED_PREFIX JSON
                           # from parse_module_params's debug branch) renders its leaves
                           # HERE, per-leaf: Ansible templates each list item as its own
                           # string, so mixed-text items ("The OS is {{ os_arch }}") keep
                           # their surrounding literal text instead of being flattened
                           # into the comma-joined string the generic substitution below
                           # would produce (issue #7, zhan9san.java). Non-string leaves
                           # keep their native type; a failing leaf raises through the
                           # same rescue chain as every other msg shape.
                           render_debug_msg_container(substitutor, msg_container)
                         else
                           (native_containers || debug_msg) && whole_single_span ? native_typed_value(substitutor, stripped_value) : nil
                         end
          unless native_typed
            # A set_fact param whose parse-time wire is a JSON container
            # with template leaves (a dict-valued set_fact: stringify_value
            # encoded the Hash to JSON at parse time, leaves intact) keeps
            # its leaf TYPES the way ansible-core templates each mapping
            # value natively - `is_mariadb: "{{ item | regex_search('X')
            # is not none }}"` is a real bool in the fact, not the
            # "True"/"False" text the flat string substitution produces
            # (xolyu.mariadb round-1300026 "Define mariadb_version.").
            # Only whole-single-span leaves are natively typed here; any
            # other templated leaf (mixed text, block tags) falls back to
            # the flat substitution, which owns those shapes.
            native_typed = native_containers ? native_typed_container_value(substitutor, stripped_value) : nil
          end
          # A MIXED value (literal text around the span) under
          # native_containers still renders to TEXT in real ansible-core -
          # native typing requires the whole value to be one span - so it
          # needs output:true's Python-repr container rendering
          # (`{{ p0 + [foo2] }}'` stores `['...']'`, not the JSON-compact
          # `["..."]'`; round 5250000, opsta.graylog's accumulated
          # graylog_search_config_paths set_fact). A whole-single-span
          # value keeps output:false in every module: its structured/
          # native handling owns the shape, and flipping it to text broke
          # the dict-shaped argsplat params (`args:` loops) that consume
          # the rendered span as structured data.
          substituted_value = native_typed || substitutor.substitute(value, strict: true, output: !whole_single_span, native: native_containers)
        rescue e : UndefinedVariableError
          # ansible-core 2.19 wraps every undefined module-arg
          # reference with the param it failed on: the task's fatal msg
          # reads "Task failed: Finalization of task args for 'MOD'
          # failed: Error while resolving value for 'KEY': 'var' is
          # undefined" (live-verified). The KEY context is added here, at
          # the only place that knows it; the caller's
          # finalize_args_failure_message adds the Finalization wrapper.
          already_wrapped = e.message.try(&.starts_with?("Error while resolving value for"))
          raise e if already_wrapped
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': #{e.message}")
        rescue e : VariableSubstitutor::FilterEngine::UnknownFilterError
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': Syntax error in template: #{e.message}")
        rescue e : VariableSubstitutor::UnknownTestError
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': Syntax error in template: #{e.message}")
        rescue e : VariableSubstitutor::TemplateSyntaxError
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': #{e.message}")
        rescue e : Krikri::PipeLookupError | Krikri::FirstFoundLookupError | Krikri::PythonLookupRunner::LookupError | FilterPluginError | TestPluginError
          # Lookup/filter/test-plugin failures ride the same finalization
          # chain - Ansible 2.19.11 fails the task with "Task failed:
          # Finalization of task args for 'MOD' failed: Error while
          # resolving value for 'KEY': <plugin error>" (live-verified
          # for each shape), never the bare "Action failed" chain a
          # non-wrapped raise fell into.
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': #{e.message}")
        rescue e : VarSubstitutor::UndecryptableVaultError
          # An undecryptable vault reference fails the same finalization
          # chain, and real 2.19 wraps the failed template itself as
          # "Error rendering template:" regardless of whether the arg is
          # a scalar or a container (live-verified 2.19.11, both shapes).
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': Error rendering template: #{e.message}")
        rescue e : Exception
          # Same routing for any LOOKUP plugin's failure ("The lookup
          # plugin 'file' failed: Unable to access ..."); everything
          # else keeps its own shape. MUST stay last: a generic rescue
          # above this line would swallow the plugin-error classes'
          # own routing.
          raise UndefinedVariableError.new("Error while resolving value for '#{key}': #{e.message}") if e.message.try(&.starts_with?("The lookup plugin '"))
          raise e
        ensure
          VarSubstitutor.pop_current_task_param if task
        end

        # A block-tag template (`{%`/`{#`) that renders to a literally
        # EMPTY string is treated as OMITTED, not as an empty-string
        # value - live-verified against ansible-core 2.19.11:
        # `content: "{% for f in restic_files %}{{ f }}\n{% endfor %}"`
        # with `restic_files: []` fails copy's own `src (or content) is
        # required` check (hbjydev.restic, round found this originally),
        # while a BARE `{{ some_empty_string_var }}`, mixed text
        # (`"prefix{{ e }}"`), a literal `content: ""`, and even a bare
        # `{{ '' }}` expression all succeed and write a real empty file
        # (verified live, all four shapes, same ansible-core version) -
        # so this is specific to block-tag rendering, not "any empty
        # content:" generally (geerlingguy.sanoid's own `content: "{{
        # sanoid_conf }}"` with `sanoid_conf: ""` must keep succeeding).
        # Only the WHOLE-VALUE case is treated this way, matching
        # OMIT_SENTINEL's own existing whole-value-vs-partial split
        # immediately below - a block tag that's only PART of a larger
        # value and happens to contribute nothing keeps the surrounding
        # literal text, it doesn't omit the whole param.
        if (value.includes?("{%") || value.includes?("{#")) && substituted_value.empty?
          substituted_value = OMIT_SENTINEL
        end

        # A whole-span template whose rendered result is empty text is
        # ambiguous at this string layer: a real empty string and a real
        # Python None both render as "", yet Ansible keeps the two
        # natively apart and its own module argspecs treat them
        # differently - an explicit None fails every `type: list` param
        # with the generic NoneType-conversion message while an empty
        # string (and an omitted param) coerce to an empty list just fine
        # (live-verified against ansible-core 2.19.11 for all four of
        # yum/dnf's `type: list` params). Found via round 900905
        # officel.httpd: every loop item's `enablerepo: ~` default made
        # ansible-playbook fail the task while this engine installed
        # the packages anyway. The hand-rolled FilterEngine's
        # nil-as-undefined collapse hides the None behind
        # `item.enablerepo | default('')` (Jinja2's default filter
        # never triggers on a DEFINED None - live-verified), but Crinja's
        # is Jinja2-faithful, so the structural re-resolution here sees
        # through it; evaluate_structured returns nil for a genuinely
        # undefined expression, which must NOT mark the param (only
        # strict-mode bare refs already raise for those, above). The
        # None-ness rides the string-only wire as NONE_SENTINEL, which
        # BasePlugin demotes back to "" for every plugin that never
        # consults explicit_null_param? - same pattern as OMIT_SENTINEL
        # directly above.
        if whole_single_span && substituted_value.empty?
          structured = begin
            VariableSubstitutor::ExpressionEvaluator.new(substitutor.vars)
              .evaluate_structured(stripped_value[2..-3].strip)
          rescue
            nil
          end
          substituted_value = Krikri::NONE_SENTINEL if structured && structured.raw.nil?
        end

        # The same strings-only-wire collapse one shape over: a whole-span
        # `{{ }}` that renders to the TEXT "[]" is either a real empty LIST
        # (`{{ empty_list_var }}` with the var `[]` - which the package
        # family no-ops, round 83246) or a STRING whose own content is
        # literally "[]" (`name: "{{ item }}"` over a with_items entry like
        # "{% if x %}apt-transport-https{% else %}[]{% endif %}",
        # wangsha.ansible_role_lynis round 29880205) - both arrive here as
        # the same wire text, and the JSON-bracket decode any list arg does
        # would read BOTH as an empty list. ansible-core keeps the two
        # apart natively: the str "[]" reaches the dnf backend whole and
        # fails the install with its own per-spec shape (msg "Failed to
        # install some of the specified packages", failures ["No package
        # [] available."], rc 1). Re-derive the span's STRUCTURED type
        # exactly like the None case above and mark a String result with
        # NON_STRING_PARAM_PREFIX, so BasePlugin hands it back to the
        # plugins that consult #non_string_param while every other consumer
        # (argspec validation, all plugins that never ask) sees the same
        # demoted plain "[]" text it always did.
        if whole_single_span && substituted_value == "[]"
          structured = begin
            VariableSubstitutor::ExpressionEvaluator.new(substitutor.vars)
              .evaluate_structured(stripped_value[2..-3].strip)
          rescue
            nil
          end
          substituted_value = Krikri::NON_STRING_PARAM_PREFIX + "[]".to_json if structured && structured.raw.is_a?(String)
        end

        # `mode:` piped through a variable (`mode: "{{ redis_conf_mode
        # }}"`, geerlingguy.redis's own style) loses its octal-ness the
        # same way a *direct* unquoted `mode: 0770` literal does (see
        # playbook_parser.cr's own #parse_task_params octal-mode comment)
        # - Crystal's YAML parser already decimal-converted the variable's
        # defining `redis_conf_mode: 0640` at vars-file parse time,
        # so #substitute above just stringifies that decimal (Int64 416)
        # as "416" verbatim. Ansible's own file module hits the
        # exact same decimal-rendered string internally, but recovers the
        # original octal digits because its `mode:` argspec is `type:
        # raw` - a *bare* single `{{ }}` template preserves the
        # variable's native Python int type instead of stringifying, and
        # the module's own `set_fs_attributes_if_different` explicitly
        # reformats an int mode via `'%04o' % mode` before ever comparing
        # or applying it. Re-derive the same octal digit text here,
        # narrowly scoped to key == "mode" (matching the parse-time fix's
        # own scope) rather than generally preserving native types for
        # every param, since only mode: has this real-Ansible-specific
        # int -> octal-string reinterpretation. rjust(4, '0') mirrors
        # `'%04o'`'s own minimum-width padding exactly ("640" from
        # 0640's decimal 416, "2770" from 02770's decimal 1528).
        #
        # This used to keep the int's plain decimal digits when they
        # already LOOKED like a valid octal mode (`\A[0-7]{3,4}\z`), to
        # protect set_fact-decimal-coerced mode strings ("1777" -> int
        # 1777 -> reformatted to "3361") - but that heuristic misfires on
        # exactly the most common YAML-octal modes, whose decimal values
        # coincidentally have octal-only digits: 0640 -> 416, 0644 ->
        # 420, 0777 -> 511. geerlingguy.redis's own `mode: "{{
        # redis_conf_mode }}"` (0640) applied as octal 416 instead, then
        # never converged against redis-server's own postinst chmod 640 -
        # changed: true on every warm run. The escape is gone because its
        # other side is now fixed at the root: set_fact's coerce no
        # longer decimal-coerces octal-mode-shaped strings into ints at
        # all (see plugins/set_fact.cr - Ansible's native typing
        # keeps a string-sourced fact a string), so every Int64 arriving
        # here is a genuine YAML-octal-derived int and to_s(8) always
        # round-trips the original octal digits.
        if key == "mode"
          stripped = value.strip
          if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
            # The structured (memoized) whole-span evaluation first: with
            # native typing, a vars entry like `m_int: "{{ 420 }}"` now
            # resolves to the INT 420 (ansible-core keeps the
            # expression's type), and the int -> octal reformat below needs
            # that int - live-verified vs 2.19.11 that `mode: "{{ 420 }}"
            # applies 0644, while the pre-native-typing string "420" was
            # applied as octal digits (mode 0o420). The raw lookup stays as
            # the fallback for anything the structured path doesn't cover
            # (a var whose stored value is already a YAML int).
            native = VariableSubstitutor::Rerender.whole_span_structured(substitutor.vars, stripped) ||
                     VariableSubstitutor::VariableLookup.new(substitutor.vars).resolve(stripped[2..-3].strip)
            if native && (raw = native.raw).is_a?(Int64)
              substituted_value = raw.to_s(8).rjust(4, '0')
            end
          end
        end

        # `{{ ... | default(omit) }}` (Ansible's magic variable for
        # dropping a parameter entirely rather than giving it any real
        # value - see OMIT_SENTINEL) - skip the key altogether instead of
        # sending the plugin a literal sentinel string as the param value.
        next if substituted_value == OMIT_SENTINEL

        # An omit that is only PART of a larger value cannot drop the
        # parameter - Ansible renders it as nothing and keeps the
        # rest (verified against ansible-core 2.19.4: with `v_omit: "{{
        # never_set | default(omit) }}"`, `msg: "[{{ v_omit }}]"` prints
        # "[]"). This engine used to emit its own raw sentinel text
        # there, so `__crystal_ansible_omit__` reached the module - and
        # a user's log, config file or command line - as if it were
        # real content.
        #
        # Deliberately AFTER the whole-value check above: mapping the
        # sentinel to "" first would turn "the whole param is omit" into
        # "the param is the empty string", which is the opposite of what
        # omit exists to do.
        if substituted_value.includes?(OMIT_SENTINEL)
          substituted_value = substituted_value.gsub(OMIT_SENTINEL, "")
        end

        result[substitutor.substitute(key)] = substituted_value
      end

      # Ansible parses a command:/shell:'s trailing `creates=`/
      # `removes=`/`chdir=`/`executable=` specials from the module args
      # AFTER templating, not before - this engine's parse-time pass
      # (PlaybookParser.extract_command_special_params) runs on the RAW
      # text, so it silently missed the shape where the whole command is
      # a `{% if %}...{% endif %}` block (found live via kamaln7.
      # swapfile): the raw text's last token there is the literal
      # `{% endif %}` tag, the `creates=...` sits inside one branch, and
      # the strip never fired - so `creates=...` reached `fallocate` as
      # a literal positional argument ("unexpected number of arguments").
      # Ansible renders the whole block FIRST (resolving to one
      # flat command line where `creates=` genuinely IS last) and only
      # then parses trailing specials - this post-render pass replicates
      # that ordering. Idempotent with the parse-time pass: for a plain
      # command the specials were already stripped and moved into named
      # params at parse time, so there's nothing trailing left here to
      # find a second time.
      if module_name
        resolved = PlaybookParser.resolve_module_name(module_name) || module_name
        if PlaybookParser::RAW_COMMAND_MODULES.includes?(resolved)
          cmd_key = result.has_key?("cmd") ? "cmd" : result.has_key?("_raw_params") ? "_raw_params" : nil
          if cmd_key && (raw_cmd = result[cmd_key]?)
            cmd, special = PlaybookParser.extract_command_special_params(raw_cmd)
            result[cmd_key] = cmd
            special.each do |special_key, special_value|
              result[special_key] = special_value unless result.has_key?(special_key)
            end
          end
        end
      end

      ordered = Hash(String, String).new
      params.each_key { |key| ordered[key] = result[key] if result.has_key?(key) }
      result.each { |key, value| ordered[key] = value unless ordered.has_key?(key) }
      ordered
    end

    # The msg Ansible produces when a task-arg templating failure
    # (strict-undefined during module-arg finalization) fails the task -
    # NOT the bare inner error text. Real wraps every
    # AnsibleUndefinedVariable with "The task includes an option with an
    # undefined variable. The error was: <text>. <text>" (the doubled
    # copy is Ansible's own message+orig_exc concatenation), then appends
    # its AnsibleError-obj context: the offending task's source location
    # from the playbook YAML and the surrounding lines with a caret.
    # Live-captured from ansible-core 2.14 (podman-diff
    # set_fact_edge_cases S1):
    #
    #   "The task includes an option with an undefined variable. The
    #   error was: 'undefined_source_var' is undefined.
    #   'undefined_source_var' is undefined\n\nThe error appears to be
    #   in '/work/case.yml': line 10, column 7, but may\nbe elsewhere in
    #   the file depending on the exact syntax problem.\n\nThe offending
    #   line appears to be:\n\n  tasks:\n    - name: \"S1 ...\"\n      ^ here\n"
    #
    # The location block is best-effort: the parser doesn't track
    # per-task source positions, so the task is located by scanning the
    # Expands a `_templated_args` param (see playbook_parser.cr's
    # whole-args-template branch, calvinbui.ansible_apt's
    # `apt: "{{ item }}"`): the value has already been substituted
    # (native whole-span rendering carries the double-quoted JSON form),
    # so a dict render becomes the module's real params and anything
    # else falls back to free-form k=v parsing - Ansible's own
    # post-template dispatch for a string args value. The sentinel key
    # never reaches the plugin (every plugin's validation now ignores
    # `_`-prefixed keys anyway).
    private def expand_templated_args(params : Hash(String, String), substitutor : VarSubstitutor, task : Task? = nil) : Hash(String, String)
      raw = params.delete("_templated_args")
      # The `{% ... %}`/`{# ... #}` string-args marker (see
      # parse_module_params's marker comment) warns through the SAME
      # once-per-task-occurrence argsplat machinery as the `{{ }}`
      # sentinel, while leaving the value's own resolution untouched -
      # Ansible's TaskArgsFinalizer warns for both delimiter families
      # (is_possibly_all_template) before anything about the rendered
      # value is known.
      block_marker = params.delete("_argsplat_block_marker")
      jinja_block_args = params.delete("_jinja_block_args")
      # Ansible warns as soon as it starts resolving such a string args layer
      # (the Ansible module's TaskArgsFinalizer.finalize), BEFORE
      # the value is known to resolve to a dict - so a `copy: "{# c #}"`
      # still gets the warning and only then fails to resolve, and so does
      # the unquoted-`{%`-token shape below (the same finalizer pass sees
      # the string layer first). `task` is
      # nil only where no Task is at hand (never today); the warning's
      # best-effort Origin needs it.
      emit_argsplat_warning(task) if task && (raw || block_marker || jinja_block_args)
      # An unquoted `{%`-starting token made Ansible finalize the WHOLE
      # free-form string as one Jinja template (see parse_module_params's
      # `_jinja_block_args` marker comment). The rendered text is not a
      # dict, so Ansible's finalizer fails the task before the module runs -
      # including in check mode - per host and per loop item, exactly where
      # this method runs. The type name is observed Ansible behaviour
      # (2.19.11): 'NoneType' when no `{% %}` block contributed any output
      # (all blocks false or empty - the rendered args resolve to nothing),
      # 'str' when at least one block produced text. The whole string is
      # rendered first like Ansible's single-template render (surfacing the
      # k=v text's own `{{ }}` spans and any block syntax error), then the
      # top-level block constructs decide the contribution - reusing the
      # same substitutor every other task param renders through, so a true
      # block's undefined reference fails with the same strict-undefined
      # finalization error.
      if jinja_block_args
        substitutor.substitute(jinja_block_args, strict: true)
        contributed = PlaybookParser.jinja_block_constructs(jinja_block_args).any? do |construct|
          rendered = substitutor.substitute(construct, strict: true)
          !(rendered.strip.empty? || rendered == OMIT_SENTINEL)
        end
        raise UndefinedVariableError.new("Task args must resolve to a 'dict' not '#{contributed ? "str" : "NoneType"}'.")
      end
      return params unless raw
      rendered = raw.strip
      expanded = params.dup
      json = (JSON.parse(rendered) rescue nil)
      if json && json.as_h?
        json.as_h.each do |key, value|
          expanded[key] = value.as_s? ? value.as_s : value.to_json
        end
      else
        kv, leftover = PlaybookParser.parse_inline_kv_params_public(rendered)
        kv.each { |key, value| expanded[key] = value }
        expanded["_raw_params"] = leftover if leftover
      end
      expanded
    end

    # ansible-core 2.19.11's warning for a task whose module args are
    # a single all-template string (`copy: "{{ some_dict }}"`, live-
    # verified against 2.19.11):
    #
    #   [WARNING]: Using a template for task args is unsafe in some
    #   situations (see https://docs.ansible.com/the Ansible module
    #   reference_appendices/faq.html#argsplat-unsafe).
    #   Origin: <file>:<line>:<col>
    #
    # Its trigger (the Ansible module's post_validate +
    # the Ansible module's TaskArgsFinalizer) is NOT "the value
    # renders to a dict": it is "this module does not take free-form
    # params AND the string args STARTS AND ENDS with a Jinja delimiter"
    # (so `{% ... %}`, `{# ... #}` count too). Modules that DO take
    # free-form params (`command:`/`shell:`/`script:`/`raw:`, see
    # module_registry.cr's RAW_COMMAND_MODULES) never warn, and a
    # non-template string fails earlier with Ansible's own "does not
    # support raw params" error - which is exactly the parser's
    # `_templated_args` sentinel condition, so keying off that sentinel
    # reproduces the same set of tasks. Gated on INJECT_FACTS_AS_VARS
    # upstream; that is true by default and krikri does not model the
    # knob.
    #
    # Live-verified print counts: ONE per task occurrence however many
    # hosts it runs on and however many loop items it has (real dedups by
    # the task's own finalization, which is cached per host and the
    # warning is keyed off the same object) - so the rendered text, which
    # carries the Origin position, is the dedup key. It is NOT printed
    # for a when:-skipped task (finalization never runs) and NOT
    # suppressed by `no_log:` (which only censors the task's result).
    @@argsplat_warning_seen = Set(String).new

    private def emit_argsplat_warning(task : Task) : Nil
      text = argsplat_warning_text(task)
      return if text.empty?
      return unless @@argsplat_warning_seen.add?(text)
      STDERR.puts text
    end

    # Best-effort Origin for the argsplat warning: the position ansible
    # gives the whole-string args scalar itself - its first character, so
    # the opening quote for a quoted value (`      ansible.builtin.copy:
    # "{{ d }}"`, 6 spaces, reports column 29, the quote's column, for
    # both double and single quotes). When the scalar sits on a line of
    # its own after the module key (nothing follows the colon), ansible's
    # caret moves to that value line instead - live-verified against
    # 2.19.11 with `  htpasswd:` + `    "{{ item }}"` reporting Origin
    # 5:5 (issue #292's real calvinbui.ansible_htpasswd role task). A
    # folded value (`module: >`) never triggers the warning at all (its
    # trailing newline keeps the string from both starting AND ending
    # with the delimiters; the stripped `>-` variant errors upstream as
    # "does not support raw params" before finalization runs).
    private def argsplat_warning_text(task : Task) : String
      path = task.source_file
      return "" unless path && task.source_line > 0 && File.file?(path)
      lines = File.read_lines(path)
      mod_idx, _col = module_key_position(lines, task)
      return "" unless mod_idx.is_a?(Int32)
      _, column = free_form_value_position(lines, mod_idx, task.module_name)
      line_num = mod_idx
      line = lines[mod_idx]
      rest = line[(line.index(':') || 0)..].to_s.lstrip
      column += 1 if rest.starts_with?("'") || rest.starts_with?("\"")
      if block_value_only_after_colon?(rest)
        next_idx = (mod_idx + 1...lines.size).find { |idx| !lines[idx].strip.empty? }
        if next_idx
          line_num = next_idx
          next_line = lines[next_idx]
          column = next_line.size - next_line.lstrip.size + 1
        end
      end

      String.build do |io|
        io << "[WARNING]: Using a template for task args is unsafe in some situations (see https://docs.ansible.com/ansible/devel/reference_appendices/faq.html#argsplat-unsafe).\n"
        io << origin_context_block(path, lines, line_num + 1, column)
        io << "\n"
      end
    end

    # A block-style scalar value: the module key's line ends at the colon
    # (apart from a YAML comment), so the string args start on the next
    # content line instead of inline after `<module>:`.
    private def block_value_only_after_colon?(after_colon : String) : Bool
      after_colon.size <= 1 || after_colon[1, 1] == "#"
    end

    # ansible-core 2.19's task-arg undefined-variable failure
    # (live-captured from 2.19.11, replacing the 2.14-era "The task
    # includes an option with an undefined variable ..." wording): the
    # fatal msg is
    #
    #   "Task failed: Finalization of task args for '<module>' failed:
    #    Error while resolving value for '<key>': '<var>' is undefined"
    #
    # and BEFORE the fatal line Ansible prints an `[ERROR]:` chain block
    # (see emit_finalization_error_block). Non-undefined errors (lookup
    # failures etc.) and already-wrapped environment:/name: keyword
    # errors keep their own real-verified wording.
    private def finalize_args_failure_message(ex : Exception, task : Task) : String
      msg = ex.message || "Failed to resolve task arguments"
      return msg unless ex.is_a?(UndefinedVariableError)
      return msg if msg.starts_with?("Error processing keyword") || msg.starts_with?("Task failed:")
      msg = msg.sub("Error while resolving value for 'cmd':", "Error while resolving value for '_raw_params':") if free_form_raw_command?(task)
      # include_vars's other args live under 'file' in krikri, but the
      # free-form path Ansible reports as '_raw_params' (issue #230).
      msg = msg.sub("Error while resolving value for 'file':", "Error while resolving value for '_raw_params':") if free_form_include_vars?(task)

      "Task failed: Finalization of task args for '#{finalization_module_name(task)}' failed: #{msg}"
    end

    # The failed result for a task-arg finalization failure: `debug` (which
    # templates its own msg inside the action plugin) fails with no `changed`
    # key; every other module - action-only ones like fail/assert/set_fact
    # included - carries changed: false. Live-verified vs 2.19.11 for
    # set_fact/assert/add_host/group_by/include_vars/pause/stat/ping/debug.
    private def finalization_failure_json(ex : Exception, task : Task) : JSON::Any
      h = Hash(String, JSON::Any).new
      unless finalization_module_name(task) == "ansible.builtin.debug"
        h["changed"] = JSON::Any.new(false)
      else
        # Ansible's debug fatal DUMP carries msg alone, but the REGISTERED
        # result does carry changed: false (live-verified vs 2.19.11:
        # `debug: msg: "{{ undefined }}" | ignore_errors | register` ->
        # {"failed": true, "exception": ..., "msg": ..., "changed":
        # false}) - so the key is dropped for the dump and backfilled at
        # register time instead.
        h["_ansible_register_changed"] = JSON::Any.new(false)
        # A looped debug item is a task-level failure: ansible prints the
        # per-item line msg-only (no loop bindings) and closes the loop with
        # the aggregate `fatal: ... "One or more items failed"`; the marker
        # routes it through the same display path as a when:-failed item.
        h["_ansible_task_error_msg_only"] = JSON::Any.new(true)
      end
      h["failed"] = JSON::Any.new(true)
      h["msg"] = JSON::Any.new(finalize_args_failure_message(ex, task))
      Krikri.mark_failed_key_order(JSON::Any.new(h), FAILED_KEY_ORDER_EXCEPTION_FIRST)
    end

    # The failed result for a KEYWORD conversion failure (a templated
    # `become:` that rendered to a non-boolean - issue #143):
    # finalization_failure_json's shape plus the marker the display path
    # needs to render Ansible's three-link [ERROR] chain ("Task failed."
    # / "Error processing keyword 'become'." / the conversion message,
    # the last two both Origin'd at the become: value - live-captured).
    # Without the marker the generic display path misroutes the brief
    # through debug:'s action-level "Action failed." shape - a segment
    # real never prints for a keyword failure, which is not an
    # action-plugin failure.
    private def become_conversion_failure_json(ex : KeywordBooleanError, task : Task) : JSON::Any
      result = finalization_failure_json(ex, task)
      result.as_h["_ansible_keyword_conversion"] = JSON.parse({
        "keyword"    => ex.keyword,
        "conversion" => "The value '#{ex.rendered}' could not be converted to 'bool'.",
        "origin"     => keyword_value_origin(task, ex.keyword),
      }.to_json)
      result
    end

    # Routes a task-keyword rescue to the right failure shape: a boolean
    # conversion failure carries the chain marker, everything else keeps
    # the plain finalization shape.
    private def keyword_failure_json(ex : UndefinedVariableError, task : Task) : JSON::Any
      return become_conversion_failure_json(ex, task) if ex.is_a?(KeywordBooleanError)
      # An undefined reference inside the become: template fails with the
      # same three-link keyword chain as the conversion failure (issue
      # #159), its innermost link being the bare "'x' is undefined".
      prefix = "Task failed: Error processing keyword 'become': "
      if (msg = ex.message) && msg.starts_with?(prefix)
        result = finalization_failure_json(ex, task)
        result.as_h["_ansible_keyword_conversion"] = JSON.parse({
          "keyword"    => "become",
          "conversion" => msg[prefix.size..],
          "origin"     => keyword_value_origin(task, "become"),
        }.to_json)
        return result
      end
      # become_user: the same three-link keyword chain, except the innermost
      # link points at the VARIABLE definition whose own value fails
      # (`ihs_user: "{{ ibm_user }}"` in defaults/), not at the keyword value
      # - live-verified vs ansible-core 2.19.11 on BertRaeymaekers.iim (#209).
      user_prefix = "Task failed: Error processing keyword 'become_user': "
      if (msg = ex.message) && msg.starts_with?(user_prefix)
        conversion = msg[user_prefix.size..]
        result = finalization_failure_json(ex, task)
        result.as_h["_ansible_keyword_conversion"] = JSON.parse({
          "keyword"           => "become_user",
          "conversion"        => conversion,
          "origin"            => keyword_value_origin(task, "become_user"),
          "conversion_origin" => undef_chain_origin_block(task, conversion),
        }.to_json)
        return result
      end
      finalization_failure_json(ex, task)
    end

    # A task keyword's VALUE's own column (the first non-space character
    # after the key's colon), scanned forward from the task's own line -
    # Ansible's keyword-failure chain points both of its lower links
    # there, not at the key (same convention timeout_keyword_value_origin
    # applies to timeout:).
    private def keyword_value_origin(task : Task, keyword : String) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)
      lines = File.read_lines(path)
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        at = line.index("#{keyword}:")
        next unless at
        next unless line[0...at].strip.empty?
        col = at + keyword.size + 1
        while col < line.size && line[col] == ' '
          col += 1
        end
        return ErrorBlock.origin_context(path, idx + 1, col + 1)
      end
      nil
    end

    # command/shell/script/raw written free-form (`command: echo {{ x }}`, also
    # folded/literal blocks) name their argument `_raw_params` in Ansible's error
    # text, krikri's parser calls it `cmd`.
    private def free_form_raw_command?(task : Task) : Bool
      return false unless PlaybookParser::RAW_COMMAND_MODULES.includes?(task.module_name)
      free_form_call?(task)
    end

    # Free-form include_vars carries its path as Ansible's `_raw_params` too
    # (`include_vars: "{{ undefined }}"` -> "Error while resolving value for
    # '_raw_params': 'undefined' is undefined", live-captured 2.19.11), but
    # the task's module name is the engine-internal `_include_vars`, which
    # free_form_call?'s as-written short-name match never finds in the
    # playbook source.
    private def free_form_include_vars?(task : Task) : Bool
      task.include_vars? && free_form_value_in_source?(task, "include_vars")
    end

    # True when the task's module key carries an inline value (`module: text`,
    # `module: >`), i.e. the argument arrives as `_raw_params` rather than a
    # `key: value` mapping.
    private def free_form_call?(task : Task) : Bool
      free_form_value_in_source?(task, task.module_name.split(".").last)
    end

    private def free_form_value_in_source?(task : Task, short_name : String) : Bool
      path = task.source_file
      return false unless path && task.source_line > 0 && File.file?(path)
      lines = File.read_lines(path)
      short = Regex.escape(short_name)
      matcher = /\A(?:ansible\.(?:builtin|legacy)\.)?#{short}:/
      ((task.source_line - 1)...Math.min(lines.size, task.source_line + 40)).each do |idx|
        stripped = lines[idx].strip.lchop("- ").strip
        next unless stripped.matches?(matcher)
        rest = stripped.split(":", 2)[1]?.to_s.strip
        return !rest.empty? && !rest.starts_with?('{')
      end
      false
    end

    # Prints a result's stashed finalization error block, deduped across
    # the whole run exactly like the inline emission path (Ansible's
    # Display dedups by full formatted message - the Origin's file:line
    # makes the text task-unique).
    def self.flush_deferred_finalization_error_block(result : JSON::Any) : Nil
      return unless text = result.as_h?.try(&.["_ansible_finalization_error_block"]?).try(&.as_s?)
      return unless @@finalization_error_chain_seen.add?(text)
      puts text
    end

    private def finalization_module_name(task : Task) : String
      name = PlaybookParser.resolve_module_name(task.module_name) ||
             fallback_finalization_module_name(task.module_name)
      # Ansible names a redirected module by its redirect target in this
      # message, even when the task was spelled ansible.builtin.* (live
      # 2.19.x: both `authorized_key:` and `ansible.builtin.authorized_key:`
      # report 'ansible.posix.authorized_key', bare `mount:` reports
      # 'ansible.posix.mount'). Dispatch still uses the builtin FQCN; only
      # the reported name follows the redirect.
      if name.starts_with?("ansible.builtin.") &&
         (redirected = CollectionIndex.builtin_module_redirect(name.lchop("ansible.builtin.")))
        return redirected
      end
      # engine-internal pseudo modules (_include_vars, ...) are real actions
      name = "ansible.builtin.#{name.lchop('_')}" if name.starts_with?('_')
      name
    end

    # When krikri has no plugin for the name, ansible's task-args
    # finalization error still names the module the way its loader would
    # resolve it: a bare name with an ansible_builtin_runtime.yml
    # redirect shows the redirected FQCN (bare `docker_swarm_service:` ->
    # 'community.docker.docker_swarm_service'), not the bare name as
    # written.
    private def fallback_finalization_module_name(as_written : String) : String
      return as_written if as_written.includes?('.')
      CollectionIndex.builtin_module_redirect(as_written) || as_written
    end

    # The `[ERROR]:` chain block ansible-core 2.19.11 prints on
    # stdout BEFORE the fatal: line for a task-arg undefined failure
    # (live-captured; three levels, each with its own Origin at the
    # playbook YAML and "<<< caused by >>>" between them):
    #
    #   [ERROR]: Task failed: Finalization of task args for 'M' failed: E
    #
    #   Task failed.
    #   Origin: f.yml:5:7            <- the task's `name` key
    #   ...2 context lines + caret
    #
    #   <<< caused by >>>
    #
    #   Finalization of task args for 'M' failed.
    #   Origin: f.yml:6:7            <- the module key line
    #
    #   <<< caused by >>>
    #
    #   E (the "Error while resolving value for 'key': ..." inner error)
    #   Origin: f.yml:7:23           <- the param's value token
    #
    # The parser doesn't track per-task source positions reliably enough to
    # point straight at the param, so each level is located by scanning the
    # task's OWN source file (the playbook for playbook tasks, the role or
    # included tasks file otherwise - ansible-core prints the block with
    # the task's defining file either way, live-captured on a role task);
    # when the task can't be located there, no block is printed.
    private def emit_finalization_error_block(task : Task, ex : UndefinedVariableError, host : Host) : Nil
      if text = finalization_error_block_text(task, ex, host)
        return unless @@finalization_error_chain_seen.add?(text)
        puts text
      end
    end

    # Renders the [ERROR] chain block's text WITHOUT printing it, so the
    # batch paths can defer the print to the failed result's own display
    # (see stash_finalization_error_block). Returns nil when the task's
    # source can't be located - no block either way, same as the emit-time
    # behavior this was split from.
    private def finalization_error_block_text(task : Task, ex : UndefinedVariableError, host : Host) : String?
      path = task.source_file || @playbook_file
      return nil unless path && File.file?(path)

      lines = File.read_lines(path)
      msg = ex.message || ""
      free_form = free_form_raw_command?(task)
      free_form_include_vars = free_form_include_vars?(task)
      msg = msg.sub("Error while resolving value for 'cmd':", "Error while resolving value for '_raw_params':") if free_form
      msg = msg.sub("Error while resolving value for 'file':", "Error while resolving value for '_raw_params':") if free_form_include_vars
      l3 = msg
      l2 = "Finalization of task args for '#{finalization_module_name(task)}' failed."
      l1 = "Task failed: Finalization of task args for '#{finalization_module_name(task)}' failed: #{msg}"

      # A test-plugin failure carries one MORE cause level: Ansible's chain
      # ends "... : The test plugin 'FQCN' failed: <cause>" and the block
      # then shows "Error while resolving value for 'KEY': The test
      # plugin 'FQCN' failed." (Origin at the param), then the bare
      # <cause> text with NO Origin (live-captured 2.19.11).
      # The TEST plugin case splits the cause into its own innermost
      # stanza; the FILTER plugin case (mandatory) keeps the full text in
      # the middle stanza with no extra level (live-captured 2.19.11).
      test_plugin_pattern = /\A(Error while resolving value for '[^']+': The test plugin '[^']+' failed): (.*)\z/m
      plugin_cause = nil
      if (m = msg.match(test_plugin_pattern)) && !m[2].empty?
        l3 = m[1] + "."
        plugin_cause = m[2]
      end

      # The undecryptable-vault case splits the same way, and its
      # innermost stanza gets its own Origin at the vault variable's
      # DEFINITION (live-captured 2.19.11; see vault_value_failure_origin
      # for the exactly-one-match rule) - when that definition can't be
      # located unambiguously the three-level block keeps the full
      # message instead, never a mislabeled Origin.
      vault_cause = nil
      if (m = msg.match(/\AError while resolving value for '([^']+)': Error rendering template: (Attempt to use undecryptable variable: .+)\z/m)) &&
         (vault_origin = vault_value_failure_origin(task, m[1], host))
        l3 = "Error while resolving value for '#{m[1]}': Error rendering template."
        vault_cause = m[2] + "\n" +
                      origin_context_block(vault_origin.path, File.read_lines(vault_origin.path), vault_origin.line, vault_origin.column)
      end

      name_line = locate_name_line(lines, task)
      if name_line
        name_idx, name_col = name_line
        # Locate by the module name AS WRITTEN in the source: for a
        # redirected builtin spelled with its FQCN
        # (`ansible.builtin.authorized_key:`) the reported name is the
        # redirect target (ansible.posix.authorized_key), which matches
        # nothing in the playbook text and would drop the whole block.
        # Engine-internal pseudo modules (include_tasks parses as
        # _include_tasks) never appear as-written, so they still rely on
        # the finalization_module_name fallback, whose short form matches
        # a bare-name line.
        module_line = locate_module_key_line(lines, name_idx, task.module_name) ||
                      locate_module_key_line(lines, name_idx, finalization_module_name(task)) ||
                      directive_mapping_module_position(lines, name_idx)
        return unless module_line
        module_idx, module_col = module_line
        two_level = false
      else
        # A task without `name:` starts at its module key: the task-level
        # and module-level origins are the same line, so Ansible prints two
        # levels - "Task failed: Finalization ... failed." then the cause.
        return unless task.source_line > 0 && task.source_line <= lines.size
        module_idx = task.source_line - 1
        module_col = task.source_col > 0 ? task.source_col : (lines[module_idx].size - lines[module_idx].lstrip.size + 1)
        name_idx, name_col = module_idx, module_col
        two_level = true
      end

      # Free-form include_tasks: has no locatable `_raw_params:` key in the
      # source - its value sits on the module key's own line, where
      # free_form_value_position's after-the-colon scan finds it
      # (live-verified vs 2.19.11: `include_tasks: "{{ state }}.yml"` ->
      # innermost Origin column 38, the value token's quote).
      # Dict-form include_tasks raises the same '_raw_params' message even
      # though its value sits on the later `file:` line (issue #202,
      # philnewm.vagrant_box_prep) - locate_param_key_position finds that
      # value's first character (quote included); the free-form scan stays
      # as the fallback for shapes with no `file:` key.
      # Free-form include_vars reaches this block through its own 'file'
      # wrapping (issue #230), and its `_raw_params` value sits on the
      # module key's line exactly like the free-form include_tasks shapes
      # below - only here free_form_value_position locates it (live-
      # captured 2.19.11: `include_vars: "{{ include_vars }}"` -> column
      # 17, the value token's quote).
      # The whole-string 'Task args must resolve to a dict' failure is
      # raised by Ansible with obj=the string args layer itself, so its
      # innermost Origin points at the value's first character on the
      # module key's line, not the module key (live-captured 2.19.11:
      # `pip: name=supervisor ...` -> 10:12) - the position
      # free_form_value_position already finds.
      dict_args_failure = msg.starts_with?("Task args must resolve to a 'dict'")
      include_tasks = ["include_tasks", "_include_tasks"].includes?(task.module_name)
      param_idx, param_col = free_form || dict_args_failure || free_form_include_vars ? free_form_value_position(lines, module_idx, task.module_name) : (locate_param_value_line(lines, module_idx, msg) || (include_tasks ? ((msg.starts_with?("Error while resolving value for '_raw_params':") ? locate_param_key_position(lines, module_idx, "file") : nil) || free_form_value_position(lines, module_idx, finalization_module_name(task))) : {module_idx, module_col}))

      # When the fourth chained stanza is emitted, the third level's text
      # shortens to the prefix alone - the inner message moves entirely
      # into the chained stanza (live-verified p12 vs 2.19.11).
      chain_stanza = chain_value_failure_stanza(task, msg)
      if chain_stanza && (cm = msg.match(/\A(Error while resolving value for '[^']+'): /))
        l3 = cm[1] + "."
      end

      # A block-style MAPPING or LIST param chains one level DEEPER still
      # (ansible-core 2.19.11 live-captured on issue #265,
      # opichon.mysql-backup's docker_container env, and issue #323,
      # s2ansible.zabbix_host's local_action zabbix_host host_groups):
      # the params stanza shortens to "Error while resolving value for
      # 'K'." with Origin at the block's FIRST entry line (a mapping key
      # or a list's dash, column = indent+1), and a fourth stanza holds
      # the plain "'V' is undefined" with Origin at the failing value
      # token's first character (quote included). Only the
      # plain-undefined message on a genuinely block-style param takes
      # this turn: a flow value (text after `K:`) and a block whose
      # entries never name V inside a `{{ }}` span keep the param's own
      # origin and the three-stanza block. The var-definition chain above
      # stays ahead: a var whose own definition bottoms out at the same
      # message is ansible's OTHER fourth-stanza shape (issue #36) - when
      # that stanza applies, this one does not.
      mapping_key_pos : {Int32, Int32}? = nil
      mapping_val_stanza : String? = nil
      if chain_stanza.nil? &&
         (mm = msg.match(/\AError while resolving value for '([^']+)': '([A-Za-z_][A-Za-z0-9_]*)' is undefined\z/)) &&
         (mp = mapping_value_failure_origin(lines, module_idx, mm[1], mm[2]))
        l3 = "Error while resolving value for '#{mm[1]}'."
        mapping_key_pos = mp[0]
        mapping_val_stanza = "'#{mm[2]}' is undefined\n" +
                             origin_context_block(path, lines, mp[1][0] + 1, mp[1][1])
      end

      text = String.build do |io|
        io << "[ERROR]: " << l1 << "\n"
        if two_level
          io << "\n" << "Task failed: Finalization of task args for '#{finalization_module_name(task)}' failed.\n"
          io << origin_context_block(path, lines, module_idx + 1, module_col)
        else
          io << "\nTask failed.\n"
          io << origin_context_block(path, lines, name_idx + 1, name_col)
          io << "\n<<< caused by >>>\n\n"
          io << l2 << "\n"
          io << origin_context_block(path, lines, module_idx + 1, module_col)
        end
        io << "\n<<< caused by >>>\n\n"
        io << l3 << "\n"
        stanza3_pos = mapping_key_pos || {param_idx, param_col}
        io << origin_context_block(path, lines, stanza3_pos[0] + 1, stanza3_pos[1])
        if mapping_val_stanza
          io << "\n<<< caused by >>>\n\n"
          io << mapping_val_stanza
          io << "\n"
        elsif cause = plugin_cause
          io << "\n<<< caused by >>>\n\n"
          io << cause << "\n"
          io << "\n"
        elsif chain_stanza
          io << "\n<<< caused by >>>\n\n"
          io << chain_stanza
          io << "\n"
        elsif vault_cause
          io << "\n<<< caused by >>>\n\n"
          io << vault_cause
          io << "\n"
        else
          io << "\n"
        end
      end
      # Same dedup rule as emit_when_error_chain's (Ansible's Display dedups
      # by full formatted message; the Origin's file:line makes the text
      # task-unique, so a looped task's failing items display the chain
      # once) - applied by the caller at print time.
      text
    end

    # Batch-build (execute_batch_group / execute_looped_task_batched)
    # prepares every member UP FRONT, before the earlier members' results
    # display - printing the [ERROR] chain block during that preparation
    # put it ahead of the PREVIOUS task's changed: line (issue #14,
    # pylabs.nginx: the block surfaced under the previous task's header,
    # ahead of its own result line). Instead the rendered text rides the
    # failed result on this private marker - the same pattern as
    # _ansible_loop_error_emitted - and the display path
    # (finish_single_task / finish_looped_task) prints it just before the
    # fatal/failed line, under the failing task's own banner.
    def self.stash_finalization_error_block(result : JSON::Any, text : String) : Nil
      result.as_h?.try &.[]=("_ansible_finalization_error_block", JSON::Any.new(text))
    end

    # The fourth chain stanza real 2.19.11 appends when the arg's
    # undefined failure came from a VARIABLE'S OWN template value
    # bottoming out at a missing name (`badvar: "{{ undefined_deep }}"`
    # consumed by `msg: "{{ 'a' ~ badvar ~ 'b' }}"`, live-verified p12
    # probe): the bare innermost message with its own Origin at the
    # DEFINITION whose value failed to render. The stanza is only
    # emitted when exactly one host-independent var layer holds a plain
    # `{{ }}`-text value that both references the missing name and
    # strictly fails WITH that name's message - anything ambiguous (or a
    # direct, non-chained undefined) keeps the three-stanza block, never
    # a mislabeled Origin.
    private def chain_value_failure_stanza(task : Task, msg : String) : String?
      m = msg.match(/\A(Error while resolving value for '([^']+)': )'([A-Za-z_][A-Za-z0-9_]*)' is undefined\z/)
      unless m
        # Same fourth stanza for an empty-key `groups[...]` miss inside the
        # arg's variable (live-verified 2.19.11, issue #319): the bare
        # lazy-dict message with Origin at the variable's definition.
        lazy = msg.match(/\AError while resolving value for '([^']+)': ('#{Regex.escape(Krikri::LAZY_TEMPLATE_DICT_TYPE)} object' has no attribute '')\z/)
        return nil unless lazy
        seed = task.params[lazy[1]]?
        origin = value_failure_var_origin(task, lazy[2], reachable_from: seed.is_a?(String) ? seed : nil)
        return nil unless origin
        return "#{lazy[2]}\n" +
          origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
      end
      # Real 2.19.11 only follows the vars actually reachable from the
      # failing arg (issue #36: other layers failing with the same
      # message but unreachable from this param don't suppress the
      # stanza) - pass the param's raw text as the reachability seed.
      seed = task.params[m[2]]?
      origin = undef_chain_var_origin(task, m[3], reachable_from: seed.is_a?(String) ? seed : nil)
      return nil unless origin
      "'#{m[3]}' is undefined\n" +
        origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
    end

    # Stanza 3 and 4's Origins for an undefined failure under a
    # block-style MAPPING or LIST param: stanza 3's Origin is the block's
    # FIRST entry line, column = indent+1 (a mapping's first key -
    # ansible-core 2.19.11 live-captured on issue #265's failing
    # docker_container env - or a list's dash itself, live-captured on
    # issue #323's host_groups at main.yml:11:9), and stanza 4's is the
    # failing value token's first character (quote included - the column
    # formula locate_param_key_position applies, so aligning whitespace
    # before the value is skipped like issue #241's). For a mapping
    # entry the token follows the entry's key+colon; for a list item it
    # follows the "- " marker itself (issue #323: `- "{{ var }}"` ->
    # column 11, the quote). Returns nil - and the previous three-stanza
    # block - unless every gate the behaviour depends on matches: the
    # `K:` line carries nothing after its colon (whitespace or a comment
    # only - a flow value keeps the param's own value position), the
    # next non-blank line is deeper than the key (a `- ` first entry
    # makes it a LIST param - the list is ansible's param level, never
    # mapping keys nested under it), and inside the block (entries until
    # indentation returns to the key's level) the first line whose
    # `{{ }}` span references V locates its token (a list item's own
    # dash line only - deeper structure under an item has no live-captured
    # token position yet, so it keeps scanning); no such line keeps the
    # param's own position.
    private def mapping_value_failure_origin(lines : Array(String), from_idx : Int32, key : String, var : String) : ({ {Int32, Int32}, {Int32, Int32} } | Nil)
      key_needle = /#{Regex.escape(key)}[ \t]*:/
      key_indent = 0
      key_line_idx = nil
      idx = from_idx + 1
      while idx < lines.size
        line = lines[idx]
        break if next_task_marker?(lines, from_idx, line)
        if (m = key_needle.match(line)) && (key_idx = m.begin(0)) && (key_idx == 0 || line[key_idx - 1].whitespace?)
          remainder = line[m.end(0)..].strip
          if remainder.empty? || remainder.starts_with?('#')
            key_line_idx = idx
            key_indent = line.size - line.lstrip.size
            break
          end
        end
        idx += 1
      end

      first_entry_idx = nil
      list_param = false
      if kl = key_line_idx
        eidx = kl + 1
        while eidx < lines.size
          line = lines[eidx]
          if line.strip.empty?
            eidx += 1
            next
          end
          break unless (line.size - line.lstrip.size) > key_indent
          list_param = line.lstrip.starts_with?("- ")
          first_entry_idx = eidx
          break
        end
      end
      return nil unless first_entry_idx

      entry_line = lines[first_entry_idx]
      key_origin : {Int32, Int32} = {first_entry_idx, (entry_line.size - entry_line.lstrip.size) + 1}

      eidx = first_entry_idx
      while eidx < lines.size
        line = lines[eidx]
        if line.strip.empty? || line.lstrip.starts_with?('#')
          eidx += 1
          next
        end
        # The param's own entries end where indentation returns to the
        # `K:` key's level - anything at or above it belongs to the task
        # (the module's next param, ignore_errors, the next task).
        return nil unless (line.size - line.lstrip.size) > key_indent
        if template_span_refs_var?(line, var)
          if list_param && line.lstrip.starts_with?("- ")
            # The list item's own value token follows the "- " marker
            # itself (issue #323: the quote at main.yml:11:11); aligning
            # whitespace after the dash is skipped like a mapping
            # entry's alignment before its value.
            item_indent = line.size - line.lstrip.size
            content = line.lstrip[2..]
            value_col = item_indent + 2 + (content.size - content.lstrip.size) + 1
            return {key_origin, {eidx, value_col}}
          elsif !list_param && (colon = line.index(':'))
            # The mapping-entry value token's first character after the
            # entry's key+colon (quote included); deeper list-item
            # entries carry no key and no token position to report, so
            # they keep scanning.
            value = line[(colon + 1)..]
            return {key_origin, {eidx, colon + 1 + ((value.size - value.lstrip.size) + 1)}}
          end
        end
        eidx += 1
      end
      nil
    end

    # Whether any `{{ ... }}` span in *line* names *var* as a whole
    # identifier: substring neighbours must not count (a failing
    # MYSQL_PASSWORD value shapes the Origin, a neighbouring
    # MYSQL_PASSWORDS line must not take its place).
    private def template_span_refs_var?(line : String, var : String) : Bool
      return false unless line.includes?("{{")
      word = /\b#{Regex.escape(var)}\b/
      pos = 0
      while start = line.index("{{", pos)
        close = line.index("}}", start + 2)
        break unless close
        return true if line[(start + 2)...close].match(word)
        pos = close + 2
      end
      false
    end

    # The unique var-layer DEFINITION whose plain-`{{ }}` own value
    # strictly fails with "'#{missing}' is undefined" - the Origin real
    # 2.19.11 points an [ERROR] chain's variable-templating link at when
    # the missing name is reached through such a var (`server_ip: "{{
    # bind_addr }}"` consumed by template:- live-captured). Shared with
    # chain_value_failure_stanza (the task-arg finalization chain's
    # fourth stanza): same layer merge, same exactly-one-match
    # protection - ambiguous or lineage-less definitions (extra vars,
    # inventory) yield nil so no origin ever gets mislabeled.
    private def undef_chain_var_origin(task : Task, missing : String, reachable_from : String? = nil) : FileVarOrigin?
      value_failure_var_origin(task, "'#{missing}' is undefined", skip_key: missing, required_text: missing, reachable_from: reachable_from)
    end

    # The unique var-layer DEFINITION whose plain-`{{ }}` own value
    # strictly fails with EXACTLY *message* - the general form of the
    # "'x' is undefined" scan above, also reached for failures whose
    # message is the value's own text (`undef(hint=...)`'s hint,
    # deekayen.cert_checker round 5460361's validate-args [ERROR]
    # chain). Same layer merge, same exactly-one-match protection -
    # ambiguous or lineage-less definitions (extra vars, inventory)
    # yield nil so no origin ever gets mislabeled.
    # REACHABLE_FROM: the failing param's raw text, when the caller knows
    # it - real 2.19.11 resolves a chain's Origin through the vars the
    # failing arg actually references, transitively, so sibling vars
    # failing with the SAME message but unreachable from that arg don't
    # make the origin ambiguous (issue #36: a role default
    # `jail_name: '{{ jail_net_ip }}'` plus an unrelated role var also
    # mentioning `jail_net_ip` kept the stanza hidden). nil (callers
    # without the param text) keeps the previous all-layers behaviour.
    private def value_failure_var_origin(task : Task, message : String, skip_key : String? = nil, required_text : String? = nil, reachable_from : String? = nil) : FileVarOrigin?
      merged = {} of String => JSON::Any
      origins = {} of String => VarOrigin
      merge_var_layer(merged, origins, @play_vars, @play_var_origins)
      merge_var_layer(merged, origins, task.role_defaults, task.role_default_origins)
      merge_var_layer(merged, origins, @all_role_defaults, @all_role_default_origins)
      merge_var_layer(merged, origins, task.role_vars, task.role_var_origins)
      merge_var_layer(merged, origins, @all_role_vars, @all_role_var_origins)
      merge_var_layer(merged, origins, task.vars, task.vars_origins)
      merge_var_layer(merged, origins, @extra_vars, @extra_var_origins)

      # The lazy-dict miss comes from subscripting the `groups` magic var,
      # which no var layer carries - without it the re-render fails on
      # `'groups' is undefined` instead and never reproduces the message.
      merged["groups"] ||= JSON::Any.new(build_groups) if message.starts_with?("'#{Krikri::LAZY_TEMPLATE_DICT_TYPE} object'")

      reachable = candidate_reachable_keys(merged, reachable_from)

      matches = [] of FileVarOrigin
      merged.each do |key, value|
        next if skip_key && key == skip_key
        next if reachable && !reachable.includes?(key)
        raw = value.raw
        if raw.is_a?(String)
          next unless raw.includes?("{{") &&
                      !raw.includes?("{%") && !raw.includes?("{#") &&
                      !UnsafeValues.unsafe_text?(raw)
          next if required_text && !raw.includes?(required_text)
          next if raw.includes?("lookup(") || raw.includes?("query(")
          origin = origins[key]?
          next unless origin.is_a?(FileVarOrigin) && origin.column > 0 && File.file?(origin.path)
          begin
            VarSubstitutor.new(vars: merged).substitute(raw, strict: true)
          rescue e : UndefinedVariableError
            next unless e.message == message
            matches << origin
          end
        else
          # A container-typed definition (a list of lazily-templated
          # items, a dict of templated values): the failing link lives in
          # a LEAF, and real's lineage points the innermost stanza at the
          # LEAF's own source position (issue #218:
          # `docker_users: ["{{ sudoer }}"]` under `when: docker_users`
          # -> Origin at the item, defaults main.yml:31:5 - not the
          # `docker_users:` key line). The same gates as the string scan
          # apply per leaf; the exactly-one-match rule protects against
          # ambiguity the same way.
          origin = origins[key]?
          next unless origin.is_a?(FileVarOrigin) && origin.column > 0 && File.file?(origin.path)
          next unless leaf_pos = failing_container_leaf_pos(key, value, message, required_text, merged, origin.path)
          matches << FileVarOrigin.new(origin.path, leaf_pos[0], leaf_pos[1])
        end
      end
      matches.size == 1 ? matches[0] : nil
    end

    # The source position of the unique string leaf inside a container
    # var's value whose strict render fails with EXACTLY *message* - the
    # leaf's own mark in the defining file's YAML source map (an item of
    # a list, a dict value), the position real 2.19.11's lineage points
    # the innermost chain stanza at for a failure reached through the
    # container. nil on zero or multiple failing leaves, or when the
    # file's source map has no unambiguous node for the leaf's path -
    # the exactly-one-match rule every origin scan here follows, so no
    # origin is ever mislabeled.
    private def failing_container_leaf_pos(key : String, value : JSON::Any, message : String, required_text : String?, vars : Hash(String, JSON::Any), file_path : String) : {Int32, Int32}?
      suffixes = [] of String
      collect_failing_leaf_paths(value, message, required_text, vars, [] of String, suffixes)
      return nil unless suffixes.size == 1
      map = Krikri::YamlSourceMap.scan(File.read(file_path))
      positions = map.all_suffix_at?("#{key}/#{suffixes[0]}")
      return nil unless positions.size == 1
      positions[0]
    end

    # The "<key>/<index>"-style path suffixes of every string leaf inside
    # *value* whose strict render fails with EXACTLY *message*, walked in
    # the container's own shape (list indices, dict keys, nested
    # containers recurse). The same gates as the string scan above apply
    # per leaf; a scan failure of any other kind is skipped, never
    # propagated - this scan only runs on error-display paths.
    private def collect_failing_leaf_paths(value : JSON::Any, message : String, required_text : String?, vars : Hash(String, JSON::Any), path : Array(String), matches : Array(String)) : Nil
      case raw = value.raw
      when Array
        raw.each_with_index do |item, idx|
          collect_failing_leaf_paths(item, message, required_text, vars, path + [idx.to_s], matches)
        end
      when Hash
        raw.each do |key, item|
          collect_failing_leaf_paths(item, message, required_text, vars, path + [key], matches)
        end
      when String
        return unless raw.includes?("{{") &&
                      !raw.includes?("{%") && !raw.includes?("{#") &&
                      !UnsafeValues.unsafe_text?(raw)
        return if required_text && !raw.includes?(required_text)
        return if raw.includes?("lookup(") || raw.includes?("query(")
        begin
          VarSubstitutor.new(vars: vars).substitute(raw, strict: true)
        rescue e : UndefinedVariableError
          matches << path.join("/") if e.message == message
        rescue
          nil
        end
      end
    end

    # The unique var-layer DEFINITION whose raw value is an encrypted
    # vault blob the supplied secrets cannot open - the Origin real
    # 2.19.11 points an arg-finalization [ERROR] chain's undecryptable-
    # variable link at, the `!vault` token of the defining vars file
    # (live-captured). Same layer merge and exactly-one-match protection
    # as value_failure_var_origin; each candidate blob is probed through
    # the substitutor so a secret that DOES decrypt it drops out, and an
    # ambiguous or lineage-less definition yields nil so no origin gets
    # mislabeled.
    private def vault_value_failure_origin(task : Task, key : String, host : Host) : FileVarOrigin?
      seed = task.params[key]?
      return nil unless seed.is_a?(String)
      merged = {} of String => JSON::Any
      origins = {} of String => VarOrigin
      merge_var_layer(merged, origins, @play_vars, @play_var_origins)
      # Real 2.19.11 points the innermost Origin at the `!vault` token of
      # a vars_files entry too (issue #196, live-captured): vars_files sit
      # above the play-var layer, below the role/task ones, so they merge
      # in the same order var_origin_for resolves a name's defining layer.
      merge_var_layer(merged, origins, load_vars_files(host), @vars_files_origins_cache[vars_files_cache_key(host)]?)
      merge_var_layer(merged, origins, task.role_defaults, task.role_default_origins)
      merge_var_layer(merged, origins, @all_role_defaults, @all_role_default_origins)
      merge_var_layer(merged, origins, task.role_vars, task.role_var_origins)
      merge_var_layer(merged, origins, @all_role_vars, @all_role_var_origins)
      merge_var_layer(merged, origins, task.vars, task.vars_origins)
      merge_var_layer(merged, origins, @extra_vars, @extra_var_origins)

      reachable = candidate_reachable_keys(merged, seed)
      matches = [] of FileVarOrigin
      merged.each do |name, value|
        next if reachable && !reachable.includes?(name)
        raw = value.raw
        next unless raw.is_a?(String) && raw.includes?("$ANSIBLE_VAULT")
        origin = origins[name]?
        next unless origin.is_a?(FileVarOrigin) && origin.column > 0 && File.file?(origin.path)
        begin
          VarSubstitutor.new(vars: merged).substitute(raw, strict: true)
        rescue VarSubstitutor::UndecryptableVaultError
          matches << origin
        rescue
          next
        end
      end
      matches.size == 1 ? matches[0] : nil
    end

    # Keys of MERGED transitively reachable from a failing param's text:
    # the identifiers named in the seed text itself, then - through each
    # reached var's own string value - the identifiers that var names,
    # until nothing new appears (a visited set, so definition cycles
    # terminate). Anything undefined in MERGED (the missing name itself)
    # drops out here; only existing candidate layers survive.
    private def candidate_reachable_keys(merged : Hash(String, JSON::Any), seed : String?) : Set(String)?
      return nil unless seed
      reachable = Set(String).new
      frontier = [] of String
      seed.scan(/[A-Za-z_][A-Za-z0-9_]*/).each do |match|
        id = match[0]
        next unless merged.has_key?(id) && reachable.add?(id)
        frontier << id
      end
      until frontier.empty?
        raw = merged[frontier.shift].raw
        next unless raw.is_a?(String)
        raw.scan(/[A-Za-z_][A-Za-z0-9_]*/).each do |match|
          id = match[0]
          if merged.has_key?(id) && reachable.add?(id)
            frontier << id
          end
        end
      end
      reachable
    end

    # The _ansible_undef_chain_origin ResultDisplay asks for: a template
    # action's undefined-variable failure (the crash-shaped one, see
    # ActionResult#crash_failure's *undef_chain*) points its second chain
    # link at the failing VALUE's DEFinition (`server_ip: "{{ bind_addr
    # }}"`) rather than the template file, exactly matching real
    # 2.19.11's chain for the same playbook. nil = leave the crash shape's
    # template-file default in place (no unique origin to show).
    private def undef_chain_origin_block(task : Task, bare_msg : String, template_path : String? = nil) : String?
      if bare_msg.starts_with?(DO_TAG_SYNTAX_PREFIX)
        origin = do_tag_var_origin(task, bare_msg, template_path)
        return nil unless origin
        return ErrorBlock.origin_context(origin.path, origin.line, origin.column)
      end
      m = bare_msg.match(/\A'([A-Za-z_][A-Za-z0-9_]*)' is undefined\z/)
      return nil unless m
      origin = undef_chain_var_origin(task, m[1])
      return nil unless origin
      ErrorBlock.origin_context(origin.path, origin.line, origin.column)
    end

    DO_TAG_SYNTAX_PREFIX = "Syntax error in template: Encountered unknown tag 'do'"

    # The unique var-layer definition whose own text holds a `{% do %}` tag
    # failing with EXACTLY *message* - ansible-core compiles the value when
    # the template reads it and points the chain's inner Origin at that
    # definition (live-verified, issue #322: defaults/main.yml's
    # `chainsmith_cert_files: |`). Same exactly-one-match rule as the other
    # origin scans, so an ambiguous definition yields nil.
    # Many role vars can carry the same `{% do %}` failure; ansible names the
    # one the template actually reads, so definitions whose key the template
    # *source* mentions win when exactly one does.
    private def do_tag_var_origin(task : Task, message : String, template_path : String? = nil) : FileVarOrigin?
      merged = {} of String => JSON::Any
      origins = {} of String => VarOrigin
      merge_var_layer(merged, origins, @play_vars, @play_var_origins)
      merge_var_layer(merged, origins, task.role_defaults, task.role_default_origins)
      merge_var_layer(merged, origins, @all_role_defaults, @all_role_default_origins)
      merge_var_layer(merged, origins, task.role_vars, task.role_var_origins)
      merge_var_layer(merged, origins, @all_role_vars, @all_role_var_origins)
      merge_var_layer(merged, origins, task.vars, task.vars_origins)
      merge_var_layer(merged, origins, @extra_vars, @extra_var_origins)
      bare = message.lchop("Syntax error in template: ")
      source = template_path && File.file?(template_path) ? File.read(template_path) : nil
      matches = [] of FileVarOrigin
      named = [] of FileVarOrigin
      merged.each do |key, value|
        raw = value.raw
        next unless raw.is_a?(String) && Krikri::TemplateDoTagScanner.do_tag_error(raw) == bare
        origin = origins[key]?
        next unless origin.is_a?(FileVarOrigin) && origin.column > 0 && File.file?(origin.path)
        matches << origin
        named << origin if source && source.matches?(/(?<![A-Za-z0-9_])#{Regex.escape(key)}(?![A-Za-z0-9_])/)
      end
      return named[0] if named.size == 1
      matches.size == 1 ? matches[0] : nil
    end

    # The executor-side hook the three action-failure result builder sites
    # call (execute_task_once, the batched loop, the handler loop): nil
    # unless the carrying result is an undefined-chain template failure
    # whose var scan resolved.
    private def undef_chain_result_origin(task : Task, action_result : ActionResult) : String?
      return nil unless action_result.undef_chain?
      detail = action_result.error_detail?
      return nil unless detail
      undef_chain_origin_block(task, detail, action_result.error_origin?)
    end

    private def merge_var_layer(merged : Hash(String, JSON::Any), origins : Hash(String, VarOrigin), values : Hash(String, JSON::Any)?, layer_origins : Hash(String, VarOrigin)?) : Nil
      return unless values
      values.each do |key, value|
        merged[key] = value
        if (lo = layer_origins) && (o = lo[key]?)
          origins[key] = o
        end
      end
    end

    # ansible-core 2.19.11 warns whenever a groupby result (a
    # GroupTuple namedtuple) lands in variable storage - task-arg
    # finalization and set_fact values both count (live-verified); the
    # warning is "[WARNING]: Type 'GroupTuple' is unsupported in variable
    # storage, converting to 'list'." with an Origin block at the param
    # KEY's own position, deduplicated like Ansible's Display dedup.
    @@groupby_storage_warnings = Set(String).new

    private def warn_groupby_storage(task : Task) : Nil
      path = task.source_file || @playbook_file
      return unless path && File.file?(path)
      task.params.each do |key, value|
        next unless groupby_reaches_storage?(value)
        lines = File.read_lines(path) rescue next
        found_module_idx, module_col = module_key_position(lines, task)
        next unless found_module_idx
        param_idx, param_col = locate_param_key_position(lines, found_module_idx, key) ||
                               {found_module_idx, module_col}
        text = "[WARNING]: Type 'GroupTuple' is unsupported in variable storage, converting to 'list'."
        dedup_key = "#{path}:#{param_idx + 1}:#{param_col}"
        next unless @@groupby_storage_warnings.add?(dedup_key)
        STDERR.puts text
        STDERR.puts origin_context_block(path, lines, param_idx + 1, param_col)
        STDERR.puts
      end
    end

    # ansible-core 2.19.11's task-arg finalization plays its parameter
    # values through variable storage, which warns whenever the value is
    # still a jinja2 Markup (a str subclass) instead of a plain str: the
    # `safe` filter hands back Markup, and the string-shaping filters that
    # route through markupsafe's soft_str (trim, string, default, d,
    # lower, upper, capitalize, title) leave it a Markup. Storage can't
    # keep the subclass, so ansible converts it to 'str' and prints
    # "[WARNING]: Type 'Markup' is unsupported in variable storage,
    # converting to 'str'." with an Origin block at the param's value
    # token (the opening quote for a quoted block-style value), deduped
    # to one display for a loop's items (live-verified vs 2.19.11).
    # Text-level approximation of ansible's value-type check -
    # live-verified shapes: "{{ item|safe|trim }}" / "{{ d | safe }}" /
    # "{{ d | safe | string }}" / "{{ d | safe | default('q') }}" warn;
    # a chain filter that rebuilds the value from scratch (replace, ...)
    # has already un-Markup'd it, and text around the expression
    # ("{{ d | safe }}/x") never yields a lone whole-value Markup, so
    # neither warns.
    @@markup_storage_warnings = Set(String).new

    private def warn_markup_storage(task : Task) : Nil
      path = task.source_file || @playbook_file
      return unless path && File.file?(path)
      task.params.each do |key, value|
        next unless markup_reaches_storage?(value)
        lines = File.read_lines(path) rescue next
        found_module_idx, module_col = module_key_position(lines, task)
        next unless found_module_idx
        param_idx, param_col = locate_param_key_position(lines, found_module_idx, key) ||
                               {found_module_idx, module_col}
        text = "[WARNING]: Type 'Markup' is unsupported in variable storage, converting to 'str'."
        dedup_key = "#{path}:#{param_idx + 1}:#{param_col}"
        next unless @@markup_storage_warnings.add?(dedup_key)
        STDERR.puts text
        STDERR.puts origin_context_block(path, lines, param_idx + 1, param_col)
        STDERR.puts
      end
    end

    MARKUP_STORAGE_PRESERVING_FILTERS = %w[trim safe string default d lower upper capitalize title]

    # True when the whole param (stripped) is one `{{ ... }}` expression
    # whose `safe`-producing Markup survives its remaining chain: every
    # filter after the last `safe` must be in
    # MARKUP_STORAGE_PRESERVING_FILTERS (any other filter hands back a
    # plain str, so storage never sees a Markup).
    private def markup_reaches_storage?(value : String) : Bool
      stripped = value.strip
      return false unless stripped.size > 4 &&
                          stripped.starts_with?("{{") && stripped.ends_with?("}}") &&
                          !stripped[2...-2].includes?("{{")
      segments = markup_filter_segments(stripped[2...-2].strip)
      safe_idx = nil
      segments.each_index { |idx| safe_idx = idx if idx > 0 && markup_filter_name(segments[idx]) == "safe" }
      return false unless safe_idx
      segments[(safe_idx + 1)..].all? { |segment| markup_filter_name(segment).in?(MARKUP_STORAGE_PRESERVING_FILTERS) }
    end

    # A filter chain's `|`-separated segments split only at the chain's
    # top level: parentheses, brackets and string literals keep their
    # content together, so an argument like default('a|b') stays one
    # segment instead of ending the passthrough check early.
    private def markup_filter_segments(inner : String) : Array(String)
      segments = [] of String
      start = 0
      depth = 0
      quote = nil
      inner.each_char_with_index do |char, idx|
        if quote
          quote = nil if char == quote
        else
          case char
          when '\'', '"'
            quote = char
          when '(', '[', '{'
            depth += 1
          when ')', ']', '}'
            depth -= 1
          when '|'
            if depth.zero?
              segments << inner[start...idx].strip
              start = idx + 1
            end
          end
        end
      end
      segments << inner[start..].strip
      segments
    end

    # A chain segment's filter name: the leading identifier it is spelled
    # with ("default" in default('q')); "" when the segment doesn't spell
    # a filter name.
    private def markup_filter_name(segment : String) : String
      (match = segment.match(/\A[A-Za-z_][A-Za-z0-9_]*/)) ? match[0] : ""
    end

    # Whether a groupby result survives to the value's storage: the
    # chain after `groupby(...)` must not transform the pairs away. A
    # `| map(...)` (attribute extraction or per-item filter) and the
    # scalar extractors (length/count/sum/join/first/last/min/max) turn
    # every GroupTuple into something else, so Ansible's warning fires only
    # for the shapes that keep the pairs (a bare result, select*/sort/
    # reverse/list, indexing). Text-level approximation of Ansible's
    # value-type check - verified for the debug: bare, map('first'),
    # selectattr and set_fact shapes against 2.19.11.
    private def groupby_reaches_storage?(value : String) : Bool
      offset = 0
      while (rel = value.index("groupby(", offset))
        start = rel
        offset = rel + 8
        rest = value[(start + "groupby(".size)..]
        depth = 1
        close = nil
        rest.each_char_with_index do |char, idx|
          depth += 1 if char == '('
          if char == ')' && (depth -= 1) == 0
            close = idx
            break
          end
        end
        next unless close
        after = rest[(close + 1)..]
        after = after.split("}}").first
        converted = after.matches?(/\|\s*(map|length|count|sum|join|first|last|min|max)\b/) ||
                    after.includes?("}}")
        return true unless converted
      end
      false
    end

    # The module key's own line/col, by name (located) or the task's
    # stamped position (nameless tasks).
    # The module key's own line/col, by name (located) or the task's
    # stamped position (nameless tasks).
    private def module_key_position(lines : Array(String), task : Task) : {Int32?, Int32}
      name_line = locate_name_line(lines, task)
      if name_line
        if module_line = locate_module_key_line(lines, name_line[0], task.module_name)
          return {module_line[0], module_line[1]}
        end
        return {nil, 0}
      end
      return {nil, 0} unless task.source_line > 0
      col = task.source_col > 0 ? task.source_col : (lines[task.source_line - 1].size - lines[task.source_line - 1].lstrip.size + 1)
      {task.source_line - 1, col}
    end

    # The value token's position for a free-form module call: on the module
    # key's own line, just past `<module>:` (Ansible's origin for `_raw_params`).
    private def free_form_value_position(lines : Array(String), module_idx : Int32, module_name : String) : {Int32, Int32}
      line = lines[module_idx]
      colon = line.index(':', line.index(module_name.split(".").last) || 0) || 0
      rest = line[(colon + 1)..]
      {module_idx, colon + 1 + (rest.size - rest.lstrip.size) + 1}
    end

    # Shared Origin renderer (also used by the task-name template-error
    # warning): `Origin: path:line:col`, a blank line, then 2 leading
    # context lines + the target line (right-aligned line numbers, tabs
    # echoed as spaces, 120-column truncation with a `...` marker) and a
    # caret line under the target column - byte-for-byte
    # ansible-core 2.19 _error_utils.SourceContext.from_origin.
    private def origin_context_block(path : String, lines : Array(String), line_num : Int, column : Int) : String
      String.build do |io|
        io << "Origin: " << File.expand_path(path) << ":" << line_num << ":" << column << "\n"
        io << "\n"

        label_width = line_num.to_s.size
        max_src_line_len = 120 - label_width - 1
        start_idx = Math.max(0, (line_num - 1) - 2)
        (start_idx..(line_num - 1)).each do |idx|
          line = lines[idx].chomp.gsub('\t', ' ')
          line = line[0...max_src_line_len - 3] + "..." if line.size > max_src_line_len
          io << (idx + 1).to_s.rjust(label_width) << (line.empty? ? "" : " ") << line << "\n"
        end
        io << " " * label_width << " " << " " * (column - 1) << "^ column " << column << "\n"
      end
    end

    # The `- name:` line whose raw name (quotes stripped) equals the
    # task's own; column is the `name` KEY's start (Ansible's task-level
    # origin points there, e.g. column 7 for `    - name:`). When a file
    # repeats a task name, ansible still Origins each failure at the
    # failing task's OWN mapping (stamped at parse), so prefer the match
    # on task.source_line - a same-named second task's error chain must
    # not pin the first copy's position (ecaepp.ansible_role_nginx
    # installation.yml, issue #338).
    private def locate_name_line(lines : Array(String), task : Task) : {Int32, Int32}?
      first : {Int32, Int32}? = nil
      lines.each_with_index do |line, idx|
        stripped = line.strip
        next unless stripped.starts_with?("- ")
        next unless (name_match = stripped.match(/\A-\s*name:\s*(.+)\z/))
        name_value = unquote_yaml_scalar_name(name_match[1].strip)
        next unless name_value == task.name
        col = line.index("name")
        return {idx, (col || 0) + 1} if col && idx == task.source_line - 1 && task.source_line > 0
        first = {idx, col + 1} if col && !first
      end
      first
    end

    # The parsed scalar value hiding in a `- name:` line's raw text: quote
    # unwrapping plus trailing-comment removal. YAML ends the scalar
    # before a ` # ...` comment, so the parsed task.name never carries the
    # comment the source line still shows: pgvillage.linux's
    # `- name: Add repository # noqa: args[module]` (issue #308) stopped
    # matching its own `- name:` line here and silently demoted its
    # argsplat-warning Origin from the module args line to the task-start
    # fallback, where real ansible reports the module line.
    # Only a `#` preceded by whitespace opens a comment on the raw text
    # (`foo#bar` stays one name), and one inside a quoted scalar is name
    # content too. A scalar only STARTS being quoted from a leading quote
    # char (quotes are otherwise ordinary, hence issue #244's plain name
    # ending in 'image_commit' keeps its quote); for a quoted scalar
    # everything after the closing quote is a comment.
    private def unquote_yaml_scalar_name(raw_name : String) : String
      first = raw_name[0]?
      if first && (first == '"' || first == '\'') && (close = raw_name.index(first, 1))
        return raw_name[1...close]
      end
      raw_name.sub(/\s+#.*\z/, "")
    end

    # Whether *line* opens the NEXT task. A `- ` line nested deeper than the
    # task's own list marker is data (a `with_items:` entry, a list-valued
    # param) and ansible's origin scan runs through it - the [ERROR] chain
    # for a looped task whose loop list precedes the module key (issue #263)
    # was dropped by stopping at the first such line.
    private def next_task_marker?(lines : Array(String), from_idx : Int32, line : String) : Bool
      return false unless line.lstrip.starts_with?("- ")
      anchor = lines[from_idx]
      anchor_indent = anchor.size - anchor.lstrip.size
      indent = line.size - line.lstrip.size
      anchor.lstrip.starts_with?("- ") ? indent <= anchor_indent : indent < anchor_indent
    end

    # The task's module key line (first non-`- ` line after the name
    # whose stripped text starts with the invoked or FQCN-stripped module
    # name); column is the key's first character.
    private def locate_module_key_line(lines : Array(String), from_idx : Int32, module_name : String) : {Int32, Int32}?
      short = module_name.split(".").last
      ((from_idx + 1)...lines.size).each do |idx|
        line = lines[idx]
        stripped = line.strip
        break if next_task_marker?(lines, from_idx, line)
        if stripped.starts_with?("#{module_name}:") || stripped.starts_with?("#{short}:")
          return {idx, line.size - line.lstrip.size + 1}
        end
      end
      nil
    end

    # A mapping-form `action:`/`local_action:` directive names its module on
    # a `module:` key, so no task line starts with the module name and
    # locate_module_key_line finds nothing (cans.ssh-authorize's
    # `local_action:` / `    module: stat`) - which used to drop the whole
    # [ERROR] chain. Real 2.19.11 still prints the chain for this shape and
    # points the middle Origin at the `module:` value's first token
    # (tasks/main.yml:4:13, live-captured) - the value-token position
    # locate_param_key_position already returns for a block-style param.
    # Only a directive key standing alone is the mapping form; a free-form
    # value names the module inline, where Ansible's own finalization never
    # reads a `module:` key out of the string, so those keep the previous
    # no-block behaviour.
    private def directive_mapping_module_position(lines : Array(String), from_idx : Int32) : {Int32, Int32}?
      directive_needle = /\A(?:ansible\.(?:builtin|legacy)\.)?(?:action|local_action)[ \t]*:/
      ((from_idx + 1)...lines.size).each do |idx|
        line = lines[idx]
        stripped = line.strip
        break if next_task_marker?(lines, from_idx, line)
        next unless (m = directive_needle.match(stripped))
        return nil unless stripped[m.end(0)..].strip.empty?
        return locate_param_key_position(lines, idx, "module")
      end
      nil
    end

    # The failing param's line - located by parsing the wrapped message's
    # "Error while resolving value for '<key>': ..." prefix; column is the
    # value token's start (quote included). Returns nil when the message
    # carries no key context or the key isn't found before the next task.
    private def locate_param_value_line(lines : Array(String), from_idx : Int32, msg : String) : {Int32, Int32}?
      return nil unless (m = msg.match(/\AError while resolving value for '([^']+)':/m))
      locate_param_key_position(lines, from_idx, m[1])
    end

    private def locate_param_key_position(lines : Array(String), from_idx : Int32, key : String) : {Int32, Int32}?
      # Flow style (`- debug: msg="..."`) / free-form k=v: the param sits
      # on the module key's own line. ansible's observed behaviour for a
      # `key=` arg (issue #237): the string args layer carries the origin,
      # so every key inside it points at the string start - the first
      # non-space char after the module key's colon, the position
      # free_form_value_position finds - not at the failing key's own
      # column; for the FIRST key that start is coincidentally the key's
      # column too (col 14 for `    - debug: msg=...`, live-verified vs
      # 2.19.11). The `key:` flow-dict needle keeps pointing at the key,
      # like the block-style scan below.
      # YAML alignment padding before a block-style key's colon is legal,
      # and ansible-core 2.19 still points the innermost Origin at the
      # VALUE token's first character through it (issue #241 round:
      # msghaleb.azure-vms' `client_id    : "..."` -> column 41, the
      # quote; even a tab between key and colon still lands there with
      # tabs counted one column each, live-captured vs 2.19.11) - so the
      # needles tolerate spaces/tabs before the colon. The key itself
      # must still stand alone, preceded by start-of-line or whitespace
      # (the `- ` list-marker case included): `client_id` is not the key
      # of an `xclient_id:` line, which would misplace the Origin onto a
      # longer identifier's match.
      module_line = lines[from_idx]
      key_needle = /#{Regex.escape(key)}[ \t]*:/
      if (m = module_line.match(key_needle)) && (key_idx = m.begin(0)) > 0 && module_line[key_idx - 1].whitespace?
        return {from_idx, key_idx + 1}
      end
      if (key_idx = module_line.index("#{key}=")) && key_idx > 0 && module_line[key_idx - 1].whitespace?
        colon_idx = module_line.index(':') || 0
        rest = module_line[(colon_idx + 1)..]
        return {from_idx, colon_idx + 1 + (rest.size - rest.lstrip.size) + 1}
      end
      # k=v args folded onto the line(s) after an EMPTY module value
      # (`user:\n    name={{ delete_user }}`): YAML folds everything after
      # the colon into ONE plain scalar, so ansible's string-args layer
      # sees a single string and - like the same-line k=v case above (issue
      # #237) - every key inside it carries the STRING's origin: the first
      # non-space char of the first following non-blank line (issue #311,
      # s2ansible.deluser: with `delete_user` undefined, ansible-core
      # 2.19.11 puts the innermost Origin at 4:5 with the caret under
      # `name=`, not at the module key's 3:3). A `key:` first line opens a
      # block-style mapping, which is a different shape: that scan below
      # must keep winning and pointing at the mapping's own value.
      if (folded_colon = module_line.index(':')) && module_line[(folded_colon + 1)..].strip.empty?
        module_indent = module_line.size - module_line.lstrip.size
        ((from_idx + 1)...lines.size).each do |idx|
          line = lines[idx]
          break if next_task_marker?(lines, from_idx, line)
          next if line.strip.empty?
          block_here = (bm = key_needle.match(line)) && (bk = bm.begin(0)) &&
                       (bk == 0 || line[bk - 1].whitespace?) &&
                       (line.size - line.lstrip.size) > module_indent
          if !block_here && (kv = line.index("#{key}=")) && (kv == 0 || line[kv - 1].whitespace?)
            return {idx, line.size - line.lstrip.size + 1}
          end
          break
        end
      end
      # k=v args that START on the module line and fold onto deeper lines
      # beneath it (`get_url: url=http://h/x.tgz` / `               dest=` /
      # `               sha256sum={{ ruby_checksum }}`): YAML folds those
      # lines into the same ONE plain scalar, so the string-args layer sees
      # a single string anchored on the module line and, exactly like the
      # same-line k=v case above (issue #237) and the empty-module-value
      # fold above (issue #311), the string carries the Origin: real 2.19
      # names the innermost Origin at the string's start ON the module line
      # even for a key that lives two lines lower (issue #336,
      # live-captured: sha256sum undefined reports the column just after
      # `get_url: `, not the module key's column, not the `sha256sum=` line).
      # The scan ends where the fold can end: a task marker, a blank line,
      # or a line at or above the module key's own column (dash list
      # markers included, which is YAML's own plain-scalar fold boundary).
      # A value opening a flow map (`{`) is a dict shape the `key=` string
      # never folds onto, so those stay with the block-style scans below.
      if (fold_colon = module_line.index(':')) && (rest = module_line[(fold_colon + 1)..]) && !rest.strip.empty? && !rest.lstrip.starts_with?('{')
        module_key_indent = module_line.index(/[^- \t]/) || 0
        ((from_idx + 1)...lines.size).each do |idx|
          line = lines[idx]
          break if next_task_marker?(lines, from_idx, line)
          break if line.strip.empty?
          break if (line.size - line.lstrip.size) <= module_key_indent
          if (kv = line.index("#{key}=")) && (kv == 0 || line[kv - 1].whitespace?)
            return {from_idx, fold_colon + 1 + (rest.size - rest.lstrip.size) + 1}
          end
        end
      end
      ((from_idx + 1)...lines.size).each do |idx|
        line = lines[idx]
        break if next_task_marker?(lines, from_idx, line)
        if (m = key_needle.match(line)) && (key_idx = m.begin(0)) && (key_idx == 0 || line[key_idx - 1].whitespace?)
          rest = line[m.end(0)..]
          column = m.end(0) + (rest.size - rest.lstrip.size) + 1
          return {idx, column}
        end
      end
      nil
    end

    # ansible-core 2.19's conditional-as-template deprecation (_engine.py
    # _normalize_and_evaluate_conditional): a conditional whose stripped
    # value starts AND ends with Jinja delimiters is first templated AS A
    # WHOLE; when that whole-template result is a non-string, Ansible emits
    # one [DEPRECATION WARNING] ... Origin block naming the conditional's
    # own YAML origin (live-captured 2.19.11). A string result is instead
    # used as an expression with NO warning (the `{{ cexpr }}` indirection
    # case), and a value that merely starts/ends with delimiters while
    # carrying operator text between spans (`{{ a }} and {{ b }}`)
    # templates to a string, so it never warns either - hence the
    # single-span restriction here. Display-only: krikri's own conditional
    # evaluation is untouched, this side channel fires at the same sites
    # real evaluates a conditional. Deduped by full text (warning line +
    # Origin) exactly like Ansible's Display._deduplicate - the same
    # conditional evaluated per host / per loop item displays once, while
    # two different tasks with the same text but different origins each
    # display. The one-time "Deprecation warnings can be disabled" hint
    # Ansible prints before the first deprecation (Display._deprecated's
    # warning() call, itself deduped) is shared via Krikri::DeprecationHint
    # (all deprecation kinds print it once per run, not once per emitter).
    @@conditional_deprecation_seen = Set(String).new
    @@when_error_chain_seen = Set(String).new
    # Same Display dedup for the arg-finalization chain: a looped task's
    # failing items all raise through execute_task_once's finalization
    # rescue, and real (whose Display dedups by full formatted message)
    # shows the chain once for the whole loop (round 5460184's looped
    # ucs_timezone items).
    @@finalization_error_chain_seen = Set(String).new
    @@loop_error_chain_seen = Set(String).new

    private def maybe_conditional_delimiters_deprecation(task : Task, raw : String, key : String, vars_context : Hash(String, JSON::Any)) : Nil
      conditional = raw.strip
      return unless conditional.size > 4 &&
                    conditional.starts_with?("{{") && conditional.ends_with?("}}") &&
                    !conditional[2...-2].includes?("{{")
      inner = conditional[2...-2].strip
      # The value probe re-evaluates the expression a second time; skip
      # side-effectful lookups so they never run twice.
      return if inner.includes?("lookup(") || inner.includes?("query(")
      value = VariableSubstitutor::JinjaRenderer.new(vars_context, decode: true).evaluate_value!(inner) rescue return
      return unless value
      return if value.as_s?

      text = conditional_deprecation_text(task, key, raw)
      return if text.empty?
      return unless @@conditional_deprecation_seen.add?(text)
      DeprecationHint.print_hint_once
      STDERR.puts text
    end

    private def conditional_deprecation_text(task : Task, key : String, raw : String) : String
      path = task.source_file || @playbook_file
      return "" unless path && File.file?(path)

      lines = File.read_lines(path)
      located = locate_name_line(lines, task)
      if located
        name_idx, _ = located
      elsif task.source_line > 0 && task.source_line <= lines.size
        # A NAMELESS task (`- debug: msg="x"` with no `name:`) still gets
        # its deprecation in real - the warning's Origin comes from the
        # task's own YAML position, not from a name. Same source-line
        # fallback emit_when_error_chain already uses; without it every
        # unnamed whole-template conditional silently skipped the warning
        # (real prints it: live-verified against ansible-playbook
        # 2.19.11).
        name_idx = task.source_line - 1
      else
        return ""
      end

      located_key = locate_conditional_origin(lines, name_idx, key, raw)
      return "" unless located_key
      key_idx, column = located_key

      String.build do |io|
        io << "[DEPRECATION WARNING]: Conditionals should not be surrounded by templating delimiters such as {{ }} or {% %}. This feature will be removed from ansible-core version 2.23.\n"
        io << origin_context_block(path, lines, key_idx + 1, column)
        io << "\n"
      end
    end

    # The conditional's own YAML origin: the `key:` line's value token
    # (column at the value's first character, quote included), or - for
    # the folded list form - the list ITEM line whose content matches the
    # raw conditional (real points each list item's origin at its own
    # line). Best-effort: the parser doesn't track per-task source
    # positions, so the task is located by its `- name:` line (same
    # approach as locate_name_line's callers).
    private def locate_conditional_origin(lines : Array(String), name_idx : Int32, key : String, raw : String) : {Int32, Int32}?
      anchor = lines[name_idx]
      anchor_indent = anchor.size - anchor.lstrip.size
      # The task's keywords ("when:"/"when" callers pass) stand at the
      # task entry's own indent; a named task's anchor is its "- name:"
      # dash line (keys = dash indent + 2), a nameless fallback's anchor
      # already IS a key line.
      task_key_indent = anchor.strip.starts_with?("- ") ? anchor_indent + 2 : anchor_indent
      ((name_idx + 1)...lines.size).each do |idx|
        line = lines[idx]
        stripped = line.strip
        # The scan runs "to the next task", and Ansible's own display
        # locates the conditional at the task's own keyword regardless
        # of what the task map happens to hold before it: a DEEPER
        # "- " line is a nested list still belonging to this task (the
        # real-role shape of issue #247 - lotusnoir.apps_consul_exporter's
        # `vars:` first_found list before its `when:`), while the next
        # task's dash sits at the anchor's own dash indent.
        break if stripped.starts_with?("- ") && (line.size - line.lstrip.size) <= task_key_indent - 2
        # Equally, a nested entry's own deeper-indented `when:` (a
        # subtask's or a nested mapping's) is not this task's keyword -
        # accepting it would mislabel the Origin.
        next unless stripped.starts_with?("#{key}:") && (line.size - line.lstrip.size) == task_key_indent
        rest = line[line.index!("#{key}:") + key.size + 1..]
        if rest.lstrip.empty?
          # Folded list form: scan the item lines for the raw conditional.
          ((idx + 1)...lines.size).each do |item_idx|
            item_line = lines[item_idx]
            item_stripped = item_line.strip
            break unless item_stripped.starts_with?("- ")
            item = item_stripped[2..].strip
            unquoted = item.gsub(/\A["']|["']\z/, "")
            next unless unquoted == raw.strip
            dash_idx = item_line.index!("- ")
            item_rest = item_line[(dash_idx + 2)..]
            column = dash_idx + 2 + (item_rest.size - item_rest.lstrip.size) + 1
            return {item_idx, column}
          end
          return nil
        end
        column = line.size - line.lstrip.size + key.size + 1 + (rest.size - rest.lstrip.size) + 1
        return {idx, column}
      end
      nil
    end

    # ansible-core 2.19 tracks each templated value's source origin
    # ("data lineage") and labels a non-boolean conditional error with
    # where the tested value was DEFINED:
    #   "Conditional result (True) was derived from value of type 'str'
    #   at '/path/playbook.yml:5:12'. Conditionals must have a boolean
    #   result."
    # With a host in scope the position comes from var_origin_for - the
    # same layer-resolution the template-error warning block already
    # uses, so a role defaults/vars definition (round 5210000,
    # ktechmidas.openvpn's `when:` on a role default) is labeled just
    # like a play-var one, and a value whose winning layer has no file
    # origin (registered result, fact, set_fact, CLI -e, inventory line)
    # stays undecorated rather than mislabeled with a file position real
    # wouldn't print. The host-less fallback keeps the original narrow
    # shape (the playbook file's own play vars, via YamlSourceMap).
    # Full lineage (deeper chains) is still not tracked; when the
    # variable isn't found the message is returned unchanged, never
    # guessed at. A compound when: expression has no single defining
    # var, so real's lineage there labels the when: token itself -
    # handled below for the one captured shape ('int', issue #21).
    # `clause_key`/`clause_raw` name the conditional clause whose strict
    # result is being decorated ("when" by default): the RUNTIME-sourced
    # and compound-expression branches below locate the ORIGINATING
    # clause's value token, so changed_when:/failed_when: callers pass
    # their own clause key and raw text, not the when: shape.
    private def decorate_conditional_value_origin(task : Task, msg : String, host : Host? = nil, operand : String? = nil, clause_key : String = "when", clause_raw : String? = nil) : String
      return msg unless msg.includes?("Conditionals must have a boolean result")
      return msg if msg.includes?(" at '") || msg.includes?(" at \"")
      # A YAML null's strict check reports no origin: real 2.19 has no
      # datatag on a NoneType value, so `vars: {nullvar: }` behind
      # `when: nullvar` (or a compound `users_group is defined and
      # users_group` with a null `users_group:`) is labeled
      # `at '<unknown>'` - no file position, unlike every other tested
      # type (issue #342, live-verified 2.19).
      if msg.includes?("was derived from value of type 'NoneType'")
        return with_origin_clause(msg, "'<unknown>'")
      end
      # A when: LIST (and a merged import_tasks: when:, issue #325) is
      # strict-checked per CLAUSE in evaluate_when_items, so the raised
      # failure belongs to the remembered failing clause and real's
      # lineage labels that clause's tested value's defining site -
      # a bare child `when: packages_accept` behind a truthy import
      # when: is labeled defaults/main.yml:3:18, not the child task's
      # when: token the joined string produced. A compound failing
      # clause has no single defining var and keeps the when-token
      # labeling the compound branch below already gives the joined
      # condition.
      raw = if operand
              operand
            elsif task.when_condition_list
              @last_failed_when_clause || task.when_condition.to_s.strip
            else
              task.when_condition.to_s.strip
            end
      unless raw.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        # ansible's `default` filter is a pass-through for a defined
        # variable, so the conditional's tested value keeps that
        # variable's own lineage: real 2.19 labels its strict-conditional
        # error with the variable's DEFINING position, not the when: token
        # (issue #251, HUIT-AcademicTechnology-Ops.ansible-role-splunk-
        # universal-forwarder: role-defaults `splunk_uf_inputs_conf_
        # template: inputs.conf.j2` behind `var | default(false)` was
        # labeled defaults/main.yml:21:33 by real and tasks/main.yml:54:9
        # by us). Only a defined non-empty string is that observed
        # pass-through shape; a fresh fallback value (`lst | d([], true)`,
        # an undefined variable) has no lineage to follow, and when even a
        # pass-through value's origin can't be found, the compound
        # when:-token labeling below stays in charge rather than guessing.
        if (h = host) && (m = raw.match(/\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*\|\s*d(?:efault)?\s*\(.*\)\s*\z/))
          ident = m[1]
          value = build_vars_context(task, h)[ident]?.try(&.raw)
          if value.is_a?(String) && !value.empty? && var_origin_for(task, h, ident, runtime_marker: true)
            return decorate_conditional_value_origin(task, msg, h, ident, clause_key, clause_raw)
          end
        end
        # An and/or chain returns one operand's own value, so real labels
        # the error with that operand variable's defining origin
        # (`nvm_dir and not nvm_profile` with both "" -> nvm_dir's play-var
        # position, live-verified 2.19.11).
        if (h = host) && (deciding = deciding_bare_operand(task, h, raw))
          return decorate_conditional_value_origin(task, msg, h, deciding, clause_key, clause_raw)
        end
        # A block: child a static import inlined needs no own-file scan:
        # the failing compound clause's token lives in the IMPORTING file
        # (the parser stamps every block descendant with the import's
        # clause positions, issue #333, ivansible.lin_rclone's install.yml
        # block child behind main.yml's
        # `when: lin_rclone_mounts |d([],true)` - real prints
        # ` at '<main.yml>:5:9'`). The failing clause text is exactly a
        # recorded import clause's key, so the lookup pins real's
        # importing-file position where the own-file scan below finds
        # nothing (no such text exists in the child's file at all). Only
        # when: callers consult it: the map holds import when: clauses
        # only, and an until:/changed_when:/failed_when: query must not
        # borrow a coincident when: text's position.
        if clause_key == "when" &&
           (clause_origin = task.imported_when_origins.try { |origins| origins[raw]? }) &&
           File.file?(clause_origin[0])
          return with_origin_clause(msg, "'#{clause_origin[0]}:#{clause_origin[1]}:#{clause_origin[2]}'")
        end
        # Any other compound when: (`x is defined and x|length`,
        # `lst | d([], true)`): the tested value is created by the
        # expression itself, and real reports the when: value token's
        # position - the same position as the second Origin: block,
        # whatever the value's type (int, str, list, ... live-verified).
        return msg unless (tok = when_token_position(task, clause_key, clause_raw))
        return with_origin_clause(msg, "'#{tok[0]}:#{tok[1]}:#{tok[2]}'")
      end
      if h = host
        origin = var_origin_for(task, h, raw, runtime_marker: true)
        # ansible's data lineage follows a stored value that is itself a
        # single-variable template: with `gitlab_cond: "{{ gitlab_flag }}"`
        # and `when: gitlab_cond`, real labels the error with the
        # INNERMOST source value's defining position (where gitlab_flag's
        # literal was written), not the templated var's own line -
        # live-verified vs 2.19.11 (issue #151). The `| default(...)`
        # spelling chains the same way. An inner var with no defined
        # origin leaves the outer origin in place rather than guessing.
        vars = build_vars_context(task, h)
        name = raw
        10.times do
          value = vars[name]?.try(&.raw)
          break unless value.is_a?(String)
          m = value.match(/\A\s*\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|\s*default\([^)]*\)\s*)?\}\}\s*\z/)
          break if m.nil?
          inner = var_origin_for(task, h, m[1], runtime_marker: true)
          break if inner.nil?
          name = m[1]
          origin = inner
        end
        case origin
        when FileVarOrigin
          return msg if origin.column <= 0
          return with_origin_clause(msg, "'#{origin.path}:#{origin.line}:#{origin.column}'")
        when TextVarOrigin
          # Real's CLI-extra-var lineage: `at "<CLI option '-e'>"` -
          # double quotes, no position (live-verified 2.19.11).
          return msg.sub(/was derived from value of type '([a-zA-Z]+)'/) do
            "was derived from value of type '#{$1}' at \"#{origin.label}\""
          end
        when RuntimeVarOrigin
          # Registered result or gathered fact: real's lineage labels
          # the conditional's own when: token position (live-verified
          # 2.19.11).
          return msg unless (tok = when_token_position(task, clause_key, clause_raw))
          return msg.sub(/was derived from value of type '([a-zA-Z]+)'/) do
            "was derived from value of type '#{$1}' at '#{tok[0]}:#{tok[1]}:#{tok[2]}'"
          end
        else
          return msg
        end
      end
      path = @playbook_file
      return msg unless path && File.file?(path)
      return msg unless pos = bare_var_definition_pos(path, task, raw)
      msg.sub(/was derived from value of type '([a-zA-Z]+)'/) do
        "was derived from value of type '#{$1}' at '#{path}:#{pos[0]}:#{pos[1]}'"
      end
    end

    # `msg` with " at <location>" appended to its "was derived from value
    # of type 'T'" clause (location already quoted).
    private def with_origin_clause(msg : String, location : String) : String
      return msg unless (type_match = msg.match(/was derived from value of type '([a-zA-Z]+)'/))
      clause = "was derived from value of type '#{type_match[1]}'"
      msg.sub(clause, "#{clause} at #{location}")
    end

    # The bare-variable operand whose own value an `a and b` / `a or b`
    # chain returned (first falsy for `and`, first truthy for `or`), or nil
    # when the chain mixes operators, reaches a non-variable operand first
    # (`not x` and comparisons yield bools, filters/calls create fresh
    # values) or the variable is unresolvable.
    private def deciding_bare_operand(task : Task, host : Host, expr : String) : String?
      # Operands after the deciding one are never evaluated (short-circuit),
      # so they may be comparisons (`nvm_dir and nvm_profile == '.bashrc'`
      # with nvm_dir "" is labeled by nvm_dir); any non-bare operand BEFORE
      # the deciding one bails out below.
      is_or = expr.matches?(/\sor\s/)
      return nil if is_or && expr.matches?(/\sand\s/)
      operands = expr.split(is_or ? /\s+or\s+/ : /\s+and\s+/)
      return nil if operands.size < 2
      vars = build_vars_context(task, host)
      operands.each do |operand|
        operand = operand.strip
        return nil unless operand.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        value = vars[operand]? || (return nil)
        truthy = case raw = value.raw
                 when Nil     then false
                 when Bool    then raw
                 when String  then !raw.empty?
                 when Int64   then raw != 0
                 when Float64 then raw != 0.0
                 when Array   then !raw.empty?
                 when Hash    then !raw.empty?
                 else              true
                 end
        return operand if truthy == is_or
      end
      nil
    end

    # Locates `name`'s value position in the playbook file: the play
    # whose YAML mapping spans the task's own source line, then that
    # play's `vars:` entry for the name.
    private def bare_var_definition_pos(path : String, task : Task, name : String) : {Int32, Int32}?
      return nil unless task.source_line > 0
      # The play-range lookup below matches on the task's line within the
      # playbook file itself - an include/role-sourced task's line refers
      # to a different file, so its vars can't be located this way.
      return nil unless task.source_file.try { |file| File.expand_path(file) == File.expand_path(path) }
      map = Krikri::YamlSourceMap.scan(File.read(path))
      play_starts = map.plays
      play_idx = nil
      play_starts.each_with_index do |(idx, start_line), i|
        next unless start_line <= task.source_line
        next_line = i + 1 < play_starts.size ? play_starts[i + 1][1] : Int32::MAX
        play_idx = idx if task.source_line < next_line
      end
      return nil unless play_idx
      map.at?("#{play_idx}/vars/#{name}")
    end

    # The when: value token's own position in the task's source file -
    # the position real's data lineage reports for a RUNTIME-sourced
    # value (registered result, gathered fact; live-verified 2.19.11).
    # Same best-effort name-line location emit_when_error_chain uses.
    # changed_when:/failed_when: reuse this same locator (issue #262):
    # their strict non-boolean errors are lineage-labeled with the
    # clause's own value token too (jgkim.atom's
    # `failed_when: return_value.rc` -> tasks/main.yml:6:16).
    private def when_token_position(task : Task, key : String = "when", raw : String? = nil) : {String, Int32, Int32}?
      path = task.source_file || @playbook_file
      return nil unless path && File.file?(path)
      lines = File.read_lines(path)
      name_idx = if (located = locate_name_line(lines, task))
                   located[0]
                 else
                   return nil unless task.source_line > 0 && task.source_line <= lines.size
                   task.source_line - 1
                 end
      locate_conditional_origin(lines, name_idx, key, raw || task.when_condition.to_s)
        .try { |(idx, col)| {File.expand_path(path), idx + 1, col} }
    end

    # Whether a WhenEvaluationError message is a conditional-EVALUATION
    # failure (the only shape ansible-core 2.19.11 decorates with
    # the two-level [ERROR] chain block and the "Task failed: "-prefixed
    # {"msg": ...} fatal JSON). Var-render failures ("Failed to render
    # task vars") keep their pre-existing display shape.
    private def conditional_evaluation_failure?(msg : String) : Bool
      inner = msg.starts_with?("Task failed: ") ? msg["Task failed: ".size..] : msg
      inner.starts_with?("Error while evaluating conditional:") || inner.starts_with?("Conditional result (") ||
        inner.starts_with?("Syntax error in expression:") ||
        # The delimiter class composes its message with the PERIOD form
        # ("Syntax error in expression. Template delimiters are not
        # supported in expressions: ..." - create_template_error's own
        # sentence, joined to the parser's cause), not the colon form
        # the filter/test-name class uses.
        inner.starts_with?("Syntax error in expression.") ||
        # A filter/test plugin's RUNTIME failure inside a conditional is
        # real 2.19's same display class, not a bare fatal line (issue
        # #247, lotusnoir.apps_consul_exporter: `when: (params | length
        # > 0)` with a first_found no-match None): the two-level [ERROR]
        # chain block and the "Task failed: "-prefixed {"msg": ...}
        # fatal JSON, exactly like the wording classes above.
        inner.starts_with?("The filter plugin ") || inner.starts_with?("The test plugin ")
    end

    # Real prints the ALLOW_BROKEN_CONDITIONALS hint after a conditional
    # failure's block for every wording class EXCEPT the compile/runtime
    # ones that end the block at the Origin (live-verified vs 2.19.11).
    private def conditional_hint_suppressed?(inner : String) : Bool
      inner.starts_with?("Error while evaluating conditional:") ||
        inner.starts_with?("Syntax error in expression:") ||
        inner.starts_with?("Syntax error in expression.") ||
        inner.starts_with?("The filter plugin ") ||
        inner.starts_with?("The test plugin ")
    end

    # The two-level [ERROR] chain Ansible prints on stdout BEFORE the fatal
    # line for a failing `when:` (live-captured 2.19.11):
    #
    #   [ERROR]: Task failed: <inner error>
    #
    #   Task failed.
    #   Origin: f.yml:4:7            <- the task's `name` key
    #
    #   <<< caused by >>>
    #
    #   <inner error>
    #   Origin: f.yml:7:13           <- the `when:` value token
    #
    # A non-boolean conditional result adds one help-text line after the
    # block (Ansible's ALLOW_BROKEN_CONDITIONALS hint). Best-effort origin:
    # the parser doesn't track per-task source positions, so the task is
    # located by its `- name:` line (same approach as
    # emit_finalization_error_block); when either origin can't be located
    # (role/include-sourced task, folded when: list), no block is printed.
    # clause_key/clause_raw name the conditional clause the chain's
    # caused-by Origin pins: the when: shape by default, and the until:
    # unknown-filter failure (issue #318) passes its own key/raw so the
    # Origin lands on the until: value token, the position real reports
    # for it there too.
    private def emit_when_error_chain(task : Task, msg : String, host : Host? = nil, clause_key : String = "when", clause_raw : String? = nil) : Nil
      msg = decorate_conditional_value_origin(task, msg, host)
      inner = msg.starts_with?("Task failed: ") ? msg["Task failed: ".size..] : msg
      return unless conditional_evaluation_failure?(msg)
      path = task.source_file || @playbook_file
      return unless path && File.file?(path)

      lines = File.read_lines(path)
      located = locate_name_line(lines, task)
      if located
        name_idx, name_col = located
      else
        # A nameless task's origin is the module key line itself (Ansible's
        # two-level shape: "Task failed." + Origin at the module key) -
        # the same fallback emit_finalization_error_block uses.
        return unless task.source_line > 0 && task.source_line <= lines.size
        name_idx = task.source_line - 1
        name_col = task.source_col > 0 ? task.source_col : (lines[name_idx].size - lines[name_idx].lstrip.size + 1)
      end

      # A when: LIST fails strict per CLAUSE, and real pins the chain's
      # "caused by" Origin on that failing clause's ITEM line: the
      # " and "-joined when_condition string matches no item in the
      # folded-list scan below, locate returned nil, and the whole chain
      # never printed (issue #330, constrict0r.desktop) - only the
      # failing clause text can match a list item. Same failing-clause
      # labeling decorate_conditional_value_origin already uses (#325);
      # the until: caller's clause_raw and every other shape stay as they
      # were.
      raw = if clause_raw
              clause_raw
            elsif clause_key == "when" && task.when_condition_list &&
                  (failing = @last_failed_when_clause)
              failing
            else
              task.when_condition.to_s
            end
      # A merged import_tasks: when:'s failing clause can be one of the
      # IMPORT line's own items - ansible evaluates the import's clauses
      # first (they prefix the merged list), so its chain's "caused by"
      # Origin belongs at that clause's recorded position in the
      # IMPORTING file (issue #328, daixijun.mysql). The own-file locate
      # below MUST be skipped then: the inlined child commonly carries an
      # identically-worded own when:, whose line the scan would find and
      # pin the Origin at the child's file instead - different file from
      # real's output. The remembered failing clause is the strict list
      # item evaluate_when_items raised on (import-inlined tasks always
      # evaluate per-clause); a lookup miss means the failing clause is
      # the child's own, and the existing branches behave as before.
      imported_clause_origin = nil
      if clause_key == "when" && (clause = @last_failed_when_clause) &&
         (imported_map = task.imported_when_origins)
        imported_clause_origin = imported_map[clause]?
      end
      if imported_clause_origin && File.file?(imported_clause_origin[0])
        cause_path = imported_clause_origin[0]
        cause_lines = File.read_lines(cause_path)
        # The stored position is already 1-based (like
        # inherited_when_origin's); the block below re-adds the 1 by
        # rendering key_idx + 1.
        key_idx = imported_clause_origin[1] - 1
        key_col = imported_clause_origin[2]
      else
        key_line = locate_conditional_origin(lines, name_idx, clause_key, raw)
        # A statically-imported task's failing `when:` lives on the IMPORTING
        # file's import_tasks: line, not in the task's own file (the parser
        # ANDed it in), so the own-file scan finds nothing - real 2.19 still
        # prints the chain, with the "caused by" Origin pinned at the import
        # line's when: VALUE token in the importing file (issue #252,
        # Jooho.okd_prerequisites: okd-host.yml's first task reports
        # tasks/main.yml's `when: node_type == 'okd-host'`).
        if key_line
          key_idx, key_col = key_line
          cause_path = path
          cause_lines = lines
        elsif (inherited = task.inherited_when_origin) &&
              (cause_path = inherited[0]) && File.file?(cause_path)
          cause_lines = File.read_lines(cause_path)
          # The stored source-map position is already 1-based (unlike
          # locate_conditional_origin's 0-based line index); the block below
          # re-adds the 1.
          key_idx = inherited[1] - 1
          key_col = inherited[2]
        else
          return
        end
      end

      # The THIRD chain record real 2.19.11 adds when the conditional's
      # missing reference was reached through a failing VAR VALUE (a
      # lazily-stored list's item, issue #218: `docker_users: ["{{
      # sudoer }}"]` under `when: docker_users`): the middle link shortens
      # to the bare "Error while evaluating conditional." and the bare
      # missing-name cause follows with its own Origin at the failing
      # value's defining site. A direct undefined reference in the when:
      # text itself has no failing value to point at - the two-record
      # block stays as it is.
      mid = nil
      cause_stanza = nil
      if (m = inner.match(/\AError while evaluating conditional: '([A-Za-z_][A-Za-z0-9_]*)' is undefined\z/)) &&
         (origin = undef_chain_var_origin(task, m[1], reachable_from: raw))
        mid = "Error while evaluating conditional."
        cause_stanza = "'#{m[1]}' is undefined\n" +
                       origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
      elsif (m = inner.match(/\AError while evaluating conditional: ('#{Regex.escape(Krikri::LAZY_TEMPLATE_DICT_TYPE)} object' has no attribute '')\z/)) &&
            (origin = value_failure_var_origin(task, m[1], reachable_from: raw))
        # Empty-key `groups[...]` miss inside a var the when: reads: the
        # same shortened middle link and var-definition cause (live-verified
        # 2.19.11, issue #319).
        mid = "Error while evaluating conditional."
        cause_stanza = "#{m[1]}\n" +
                       origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
      end

      text = String.build do |io|
        io << "[ERROR]: Task failed: " << inner << "\n"
        io << "\nTask failed.\n"
        io << origin_context_block(path, lines, name_idx + 1, name_col)
        io << "\n<<< caused by >>>\n\n"
        io << (mid || inner) << "\n"
        io << origin_context_block(cause_path, cause_lines, key_idx + 1, key_col)
        if cause_stanza
          io << "\n<<< caused by >>>\n\n"
          io << cause_stanza
          io << "\n"
        else
          io << "\n"
        end
        # Real prints the ALLOW_BROKEN_CONDITIONALS hint after the chain
        # for every conditional failure EXCEPT the compile/runtime
        # wording classes that don't get it (live-verified vs 2.19.11: an
        # undefined reference, a "Syntax error in expression:"
        # filter/test-name failure, and a filter/test plugin's runtime
        # failure (issue #247) all end the block at the Origin; the
        # non-bool "Conditional result" failure carries the hint).
        unless conditional_hint_suppressed?(inner)
          io << "Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.\n"
          io << "\n"
        end
      end
      # Ansible's Display dedups by full formatted message; the Origin's
      # file:line makes the text task-unique, so a looped task's failing
      # items display the chain once.
      return unless @@when_error_chain_seen.add?(text)
      puts text
    end

    # The `[ERROR]:` chain block real 2.19.11 prints on stdout for a
    # loop-source / loop-item templating failure (live-captured):
    #
    #   [ERROR]: Task failed: 'nosuch' is undefined
    #
    #   Task failed.
    #   Origin: <the task's name key>
    #
    #   <<< caused by >>>
    #
    #   'nosuch' is undefined
    #   Origin: <the defining site of the value that referenced it>
    #
    # The cause's Origin comes from the same value-failure scan the
    # arg-finalization chain uses (undef_chain_var_origin); when no unique
    # defining var qualifies, the cause stanza prints without an Origin
    # rather than a mislabeled one. The caller marks the failed result
    # (_ansible_loop_error_emitted) so ResultDisplay does not print a
    # second, differently-shaped block for the same failure.
    private def emit_loop_error_chain(task : Task, msg : String) : Nil
      inner = msg.starts_with?("Task failed: ") ? msg["Task failed: ".size..] : msg
      path = task.source_file || @playbook_file
      return unless path && File.file?(path)

      lines = File.read_lines(path)
      if located = locate_name_line(lines, task)
        name_idx, name_col = located
      else
        return unless task.source_line > 0 && task.source_line <= lines.size
        name_idx = task.source_line - 1
        name_col = task.source_col > 0 ? task.source_col : (lines[name_idx].size - lines[name_idx].lstrip.size + 1)
      end

      cause_context = nil
      if m = inner.to_s.match(/\A'([A-Za-z_][A-Za-z0-9_]*)' is undefined\z/)
        if origin = undef_chain_var_origin(task, m[1])
          cause_context = origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
        elsif task_has_loop_source?(task) && (pos = locate_loop_source_line(lines, task, missing: m[1]))
          # An UNDEFINED loop source (`loop: "{{ wordpress_sites }}"`) has
          # no defining var for undef_chain_var_origin to find - but real
          # still pins the cause stanza's Origin at the loop keyword's
          # VALUE token, the reference site itself (live-verified vs
          # 2.19.11: `loop: "{{ wordpress_sites }}"` reports the loop
          # line/column with the usual excerpt+caret, issue #12,
          # armov.zabbix_agent2_lit_trellis_custom). Without this the
          # caused-by stanza printed with no Origin block at all. The
          # undefined name goes along so a literal list's Origin lands on
          # the failing ELEMENT rather than the first one (issue #228).
          cause_context = origin_context_block(path, lines, pos[0] + 1, pos[1])
        end
      elsif inner.to_s.starts_with?("'#{Krikri::LAZY_TEMPLATE_DICT_TYPE} object'") &&
            task_has_loop_source?(task) &&
            (origin = value_failure_var_origin(task, inner.to_s))
        # An empty-string subscript key fails inside the loop source's
        # variable (`zk_hosts_list: '{{ groups[zk_inventory_group] ... }}'`
        # consumed by `loop: '{{ zk_hosts_list }}'`); real 2.19.11 points
        # the cause stanza at that variable's defining value, not at the
        # loop keyword (live-verified, issue #319).
        cause_context = origin_context_block(origin.path, File.read_lines(origin.path), origin.line, origin.column)
      elsif inner.to_s.match(/\Aobject of type '[^']+' has no attribute '[^']+'\z/) &&
            task_has_loop_source?(task) &&
            (pos = locate_loop_source_line(lines, task))
        # A loop source that IS defined but has the wrong shape (`loop:
        # "{{ sensu_backend.namespaces }}"` with sensu_backend a dict)
        # gets the same loop-VALUE-token Origin on its cause stanza as
        # the undefined case above - live-verified vs 2.19.11, issue
        # #239. No `missing:` name: there is no undefined variable for
        # the element-narrowing to key on.
        cause_context = origin_context_block(path, lines, pos[0] + 1, pos[1])
      end

      text = String.build do |io|
        io << "[ERROR]: Task failed: " << inner << "\n"
        io << "\nTask failed.\n"
        io << origin_context_block(path, lines, name_idx + 1, name_col)
        io << "\n<<< caused by >>>\n\n"
        io << inner << "\n"
        io << cause_context if cause_context
        io << "\n"
      end
      return unless @@loop_error_chain_seen.add?(text)
      puts text
    end

    # environment: - strict-undefined substitution for both accepted
    # forms, meant to run inside the same protected "finalization of task
    # args" block as substitute_task_params so a referenced-but-undefined
    # variable FAILS the task (Ansible: "Error processing keyword
    # 'environment': 'proxy_env' is undefined") instead of rendering the
    # lenient "undefined" sentinel into an env var, ryandaniels.
    # server_update_reboot round 300094. Dict form: keys and values are
    # each templated strictly (Ansible templates the keyword's whole
    # value). String form (`environment: "{{ proxy_env }}"`): a single
    # bare {{ }} span resolves natively so a variable holding a dict
    # stays a dict; anything else must render to a JSON object.
    private def substitute_task_environment(task : Task, substitutor : VarSubstitutor) : Hash(String, String)?
      return nil unless task.environment || task.environment_raw

      begin
        if env = task.environment
          substituted = Hash(String, String).new
          env.each do |key, value|
            substituted[substitutor.substitute(key, strict: true)] = substitutor.substitute(value, strict: true)
          end
          substituted
        elsif raw = task.environment_raw
          stripped = raw.strip
          # Ansible never fails a task over an environment value it cannot
          # turn into a dict - it warns "could not parse environment value,
          # skipping" and runs the task with no extra env (same reason the
          # non-dict branch below returns nil). An empty raw used to reach
          # JSON.parse("") and crash finalization with "unexpected token
          # '<EOF>' at line 1, column 1" before the task ever ran
          # (lifeofguenter.nginx round 5250092's bare `environment:` key).
          return nil if stripped.empty?
          native = if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
                     VariableSubstitutor::VariableLookup.new(substitutor.vars).resolve(stripped[2..-3].strip)
                   end

          resolved_object = native.try(&.as_h?)
          unless resolved_object
            rendered = native ? native.to_s : substitutor.substitute(raw, strict: true)
            # Ansible drops the whole environment when its template renders
            # to `omit` (e.g. `environment: "{{ proxy_env | default(omit) }}"`
            # with proxy_env undefined) instead of passing the omit marker
            # through, which would fail JSON parsing downstream.
            return nil if rendered.includes?(OMIT_SENTINEL)
            parsed = JSON.parse(rendered)
            object = parsed.as_h?
            # Ansible never fails a task over a non-dict environment
            # value - it just warns "could not parse environment value,
            # skipping" and treats the environment as empty. The common
            # trigger is a role default like `proxy_env: []`, meant to be
            # overridden by the caller with a real dict but left as an
            # empty list otherwise (ryandaniels.connectivity_test round
            # 601446: the whole package: task failed here in krikri while
            # ansible-playbook just installed the packages with no
            # extra env). Confirmed against ansible-core 2.19 for `[]`, a
            # non-empty list, and a plain string - none of those raise.
            return nil unless object
            resolved_object = object
          end

          stringified = Hash(String, String).new
          resolved_object.each { |key, value| stringified[key] = value.as_s? ? value.as_s : value.to_s }
          stringified
        end
      rescue e : UndefinedVariableError
        raise UndefinedVariableError.new("Error processing keyword 'environment': #{e.message}")
      end
    end

    # An enclosing block:'s `name:` keyword - strict-undefined templating
    # of the whole enclosing chain (outermost first) at child-execution
    # time, raising the same failure shape the `environment:` handler
    # above produces: ansible-core 2.19 fails the child task with
    # "Task failed: Error processing keyword 'name': 'container_name' is
    # undefined" when the block name's chain bottoms out at a variable
    # set nowhere (round 813203, ikke_t.podman_container_systemd run
    # without grafana_podman's `container_name` above it - this engine
    # rendered the block name leniently for display and kept executing
    # deep into the role, diverging on every counter after). The strict
    # substitute reports the INNERMOST missing name (see
    # #raise_if_nested_value_undefined), matching Ansible. Only
    # fires when the child actually goes to run: Ansible finalizes
    # the block name after the child's own `when:` passes, so a
    # when-skipped child sails through and the failure lands on the next
    # child that runs (live-verified against 2.19.11). A task's OWN name
    # stays lenient - Ansible banners it as "<< error 1 - 'nope' is
    # undefined >>" and still runs/skips it normally.
    private def substitute_block_name_chain(task : Task, substitutor : VarSubstitutor) : Nil
      return unless chain = task.block_name_chain

      chain.each do |raw_name|
        next unless raw_name.includes?("{{")
        begin
          substitutor.substitute(raw_name, strict: true)
        rescue e : UndefinedVariableError
          raise UndefinedVariableError.new("Task failed: Error processing keyword 'name': #{e.message}")
        end
      end
    end

    # For copy:/template:/assemble:-style controller src resolution shared
    # by script: and unarchive:: a relative src resolves through Ansible's
    # _find_needle dwim stack - EXACTLY the ordered NeedleLookup.candidates
    # list a miss reports in "Searched in:" - so the resolver can never
    # skip a path the error message advertises. The resolver used to check
    # only <role>/files/<src>, <playbook>/<src> and the cwd, so a role
    # file addressed with its own files/ prefix (`script: files/x.py`
    # living at <role>/files/x.py) resolved nowhere even though the
    # reported search list contained it (lukapetrovic-git.ubuntu_patch's
    # `script: files/get_upgraded_packages.py`, issue #10); the miss
    # branch then failed with a Searched-in list naming the existing file.
    # The plugin subprocess itself has no concept of roles, so this has to
    # happen here, before the config is handed off. The cwd fallback stays
    # as a last-resort extra beyond Ansible's list (kept for scripts run
    # from a directory Ansible would not find the file from either).
    private def resolve_script_path(local_path : String, task : Task) : String?
      candidates = if local_path.starts_with?('/') || local_path.starts_with?("~")
                     [] of String
                   else
                     NeedleLookup.candidates(
                       NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)),
                       File.expand_path(@playbook_dir), "files", local_path)
                   end
      resolved = candidates.find { |candidate| File.exists?(candidate) }
      return File.expand_path(resolved) if resolved
      return File.expand_path(local_path) if File.exists?(local_path)
      nil
    end

    # assemble:'s `src` defaults to `remote_src: true` (unlike copy:/
    # template:/unarchive:) - the common real-world shape is fragments
    # already deployed on the target by earlier copy:/template: tasks, so
    # no staging happens by default. Only `remote_src: false` (src names a
    # controller-side directory instead) needs the directory SCP'd up
    # first, same approach as copy:'s stage_directory_copy_source.
  end
end
