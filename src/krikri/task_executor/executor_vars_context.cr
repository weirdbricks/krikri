require "./executor"
require "krikri-jinja/krikri_jinja"
require "../jinja_host_context"

module Krikri
  class TaskExecutor
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
      # already have" - real Ansible's own actual precedence, unchanged
      # from what `VariableContext.build`'s ordering used to guarantee
      # via unconditional overwrite-in-priority-order instead.
      vars_context = base_context_a_for(host).dup

      # Synthesized here (not in the cached baseA below) so the legacy
      # spellings can be withheld from loop-source resolution - see
      # #synthesize_legacy_ssh_aliases and #loop_source_vars_context.
      synthesize_legacy_ssh_aliases(vars_context) if include_legacy_ssh_aliases
      # vars_files: sit ABOVE play vars and below role/task vars - real
      # Ansible's documented order, verified live: a name set in both
      # `vars:` and a vars_file resolves to the FILE's value, and a later
      # file beats an earlier one. Merged here, straight after the tier
      # holding play_vars, so role_vars/task.vars below still win.
      unless @vars_files.empty?
        load_vars_files(host).each { |key, value| vars_context[key] = value }
      end

      # Play-wide role layers. Real Ansible's precedence here was
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
      # REGISTERED variable: real Ansible ranks registered vars (19) well
      # above role vars (15), and baseA already holds them. Verified
      # against ansible-core 2.19.4 - a task that registers into a name
      # its own role's vars/main.yml also defines resolves to the
      # REGISTERED result there, where this engine used to hand back the
      # role var and lose the command's output entirely.
      registered = @registered_vars[host.name]

      # Publish this host's execution-resolved variable names (every
      # register:/set_fact: write, which always outrank role/task vars in
      # the ladder above, so a tagged name's context value IS the resolved
      # one) for the recursive re-templating gate - see VarSubstitutor's
      # @@resolved_var_names comment for why the content-based check alone
      # cannot tell a resolved result from a YAML-defined template.
      resolved_names = Set(String).new(registered.keys)
      @set_facts[host.name]?.try(&.each_key { |key| resolved_names.add(key) })
      VarSubstitutor.set_resolved_var_names(host.name, resolved_names)

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
        # role_name (unprefixed) is real Ansible's own magic var - the
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

      # `ansible_facts` - the same facts again, under their unprefixed
      # names, as one dict. Real Ansible exposes every fact both ways
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
      unless @facts[host.name].empty?
        vars_context["ansible_facts"] = JSON::Any.new(facts_dict_for(host.name))
      end

      vars_context["hostvars"] = JSON::Any.new(build_hostvars)
      vars_context["groups"] = JSON::Any.new(build_groups)

      # ansible_play_hosts_all/ansible_play_hosts - real Ansible magic
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
      # against (no match in an empty file) - while real ansible-
      # playbook, which has always populated this var, succeeded.
      play_host_names = @hosts.map { |hval| JSON::Any.new(hval.name) }
      vars_context["ansible_play_hosts_all"] = JSON::Any.new(play_host_names)
      vars_context["ansible_play_hosts"] = JSON::Any.new(play_host_names)
      vars_context["ansible_version"] = ANSIBLE_VERSION_MAGIC_VAR
      # ansible_check_mode - real Ansible magic var (true under --check,
      # false on a real run), entirely unimplemented before. Real
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
      # ansible_diff_mode - real Ansible magic var (true under --diff),
      # the same gap class as ansible_check_mode right above (bound
      # there but not here, so an idiom pairing the two in one
      # conditional half-worked). Found benchmarking
      # linux-system-roles.firewall round 970345: its "Show diffs" task
      # guards with `when: ansible_check_mode or ansible_diff_mode or
      # ...`, which hard-failed ("'ansible_diff_mode' is undefined")
      # where real ansible-playbook just skips.
      vars_context["ansible_diff_mode"] = JSON::Any.new(@diff_mode)
      vars_context["ansible_verbosity"] = JSON::Any.new(@verbosity.to_i64)
      apply_path_magic_vars(vars_context)

      # ansible_connection - real Ansible always resolves this magic var
      # (defaults "smart", which itself resolves to "ssh" for a remote
      # host, "local" for the controller) even when nothing sets it
      # explicitly (verified against real ansible-playbook: `{{
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
      # pre-loop render. Real Ansible only ever evaluates a looped task's
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
      # exactly as real Ansible does (verified: a play-level
      # `remote_user: playuser` renders `{{ ansible_user }}` as
      # playuser, and a task's own remote_user: overrides it for that
      # task). Applied before extra-vars below, which still outrank it.
      if user = task.remote_user || @remote_user
        vars_context["ansible_user"] = JSON::Any.new(user)
      end

      # Last word, deliberately: -e/--extra-vars outranks every other
      # scope, including a `set_fact` executed earlier in the same play
      # (facts arrive via base_context_b above, so applying these after
      # it is what reproduces real Ansible's "you cannot set_fact over an
      # extra-var" behavior).
      @extra_vars.each { |key, value| vars_context[key] = value }

      # Real Ansible's `vars` magic variable: a dict of every variable in
      # scope, most often used for a membership test rather than to read
      # a value - `prometheus.prometheus`'s own preflight does
      # `__common_parent_role_short_name ~ '_skip_install' not in vars`,
      # which is what surfaced its absence (round 198: crystal failed
      # that task with "'vars' is undefined" while real ansible-playbook
      # completed all 33 tasks, blocking the whole collection).
      #
      # Built LAST so it sees every other magic var, and deliberately
      # excludes itself - `vars["vars"]` would be an infinite structure,
      # and real Ansible does not expose one either.
      #
      # Cheap despite appearances: JSON::Any wraps a reference, so this
      # is a hash of N pointer copies, not a deep copy of the context.
      # Skipping "vars" is not belt-and-braces: vars_context is layered
      # on cached base contexts (see base_context_a/b), so an earlier
      # task's `vars` key is genuinely present here and would nest one
      # snapshot inside the next, growing per task. Verified against real
      # ansible-core 2.19.4, which reports `'vars' not in vars`.
      self_view = Hash(String, JSON::Any).new(initial_capacity: vars_context.size)
      vars_context.each do |key, value|
        next if key == "vars"
        self_view[key] = value
      end
      vars_context["vars"] = JSON::Any.new(self_view)

      vars_context
    end

    # Real Ansible's variable manager treats `ansible_ssh_user`/
    # `ansible_ssh_host`/`ansible_ssh_port` as deprecated-but-still-
    # honored aliases of `ansible_user`/`ansible_host`/`ansible_port` -
    # but only in the FINAL task-argument templating context. Loop-source
    # resolution (and the loop items it recursively renders) sees an
    # earlier vars snapshot where the synthesis never happened, so
    # `loop: ["{{ ansible_ssh_user }}"]` - or a role default like
    # f500.bashrc's own `bashrc_users: ["{{ ansible_ssh_user }}"]`
    # (round900321) later fed to `with_items:` - hard-fails with
    # "'ansible_ssh_user' is undefined" on real ansible-playbook, while
    # the same reference in a plain task arg (or a `when:`, or a role
    # default reached through task-arg templating - round168's
    # geerlingguy.phergie `phergie_user: "{{ ansible_ssh_user }}"`
    # default feeding `file: {owner: "{{ phergie_user }}"}`) resolves
    # fine. Live-verified all four shapes against real ansible-playbook
    # this session. This engine used to synthesize the aliases inside the
    # cached baseA layer, making them visible to EVERYTHING - which
    # resolved f500.bashrc's defaults the way phergie's resolve, where
    # real Ansible fails them. Synthesized with `||=` in both directions,
    # so an inventory line that already sets the legacy spelling
    # explicitly still wins and stays a REAL variable - visible in loop
    # sources too, exactly as real Ansible treats an explicitly-set var.
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
    # absent (real Ansible's own scoping - see #build_vars_context's
    # synthesis comment for the verified matrix). Cheap in the common
    # case: a full alias-free rebuild is only needed when a legacy
    # spelling is present at all - if none of the three keys is in the
    # context, neither a synthesized nor an explicit copy exists, so any
    # lookup resolves identically either way and the caller's own context
    # is returned as-is. An EXPLICITLY-set legacy spelling (inventory/
    # play vars/task vars) survives the rebuild - it's a real variable,
    # visible in loop sources exactly as real Ansible treats it.
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
      # every consumer, but real Ansible's alias synthesis is visible
      # only in final task-arg templating - loop-source resolution (and
      # the loop items it recursively renders) sees a vars snapshot
      # without it (round900321 f500.bashrc's
      # `bashrc_users: ["{{ ansible_ssh_user }}"]` default fails
      # `with_items: "{{ bashrc_users }}"` on real ansible-playbook).
      # See #build_vars_context's own synthesis comment for the full
      # verified matrix.

      # Ordinary gathered facts (setup:/package_facts:/service_facts:/
      # etc, i.e. everything in @facts that ISN'T also in @set_facts)
      # fill in here LAST, via `||=` - real Ansible's "host facts" tier
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
          facts_dict[key.lchop("ansible_")] = value
        end
        facts_dict
      end
    end

    # Real Ansible's `groups` magic variable - a dict of every inventory
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
    # explicit group) - matches real Ansible, where 'all' always means
    # every host regardless of how the inventory file grouped things.
    private def build_groups : Hash(String, JSON::Any)
      if (cache = @groups_cache) && @groups_cache_generation == @hv_generation
        return cache
      end

      result = Hash(String, JSON::Any).new
      if inventory = @inventory
        inventory.groups.each do |name, _group|
          # hosts_in_group, not group.hosts: a parent group defined via
          # :children has an empty hosts hash of its own, so groups['prod']
          # came back as [] for every such group.
          result[name] = JSON::Any.new(inventory.hosts_in_group(name).map { |host| JSON::Any.new(host.name) })
        end
        result["all"] = JSON::Any.new(inventory.hosts.keys.map { |hostname| JSON::Any.new(hostname) })
        # ungrouped - real Ansible's own groups magic var always carries
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

    # Real Ansible's `hostvars[<name>]` magic variable - a dict of every
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
    # host) rather than cached - real Ansible's own hostvars reflects a
    # set_fact:/register: made by ANY host earlier in the same play, so
    # a stale snapshot would miss updates. Deliberately narrower than a
    # full recursive #build_vars_context call per other host (which
    # would also need its own "hostvars" key excluded to avoid infinite
    # recursion) - inventory vars + facts + registered vars covers every
    # real-world hostvars[...] use seen so far.
    # playbook_dir / inventory_dir / inventory_file - real Ansible's path
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
    # real Ansible - so a role's `inventory_file is defined` guard reads
    # the same here. A DIRECTORY inventory sets `inventory_dir` to the
    # directory itself and `inventory_file` to its single source file,
    # leaving the latter undefined when several sources make "the"
    # inventory file ambiguous.
    #
    # Both of those shapes are handled here but not reachable yet: this
    # engine's inventory loader defaults to `inventory.ini` instead of
    # real Ansible's implicit localhost when `-i` is omitted, and cannot
    # load a directory of inventory sources at all (it tries to execute
    # it as a dynamic inventory script). Those are separate, pre-existing
    # gaps in the loader, not in these magic vars.
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
        entry["inventory_hostname"] = JSON::Any.new(other_host.name)
        # No synthesized ansible_host here: real Ansible's hostvars magic
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
        # a fabricated value, letting a bad-inventory playbook real
        # Ansible aborts on task 1 run on with hostname garbage in place
        # of the IP list.
        result[other_host.name] = JSON::Any.new(entry)
      end
      # Real ansible-core's InventoryManager ALWAYS synthesizes an implicit
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
      # its real entry untouched, matching real Ansible's explicit-over-
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
            # case: real Ansible hard-fails the task that uses the var with
            # "No filter named 'X'." (a real Jinja2 TemplateAssertionError -
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

      KrikriJinja.evaluate_expression(
        inner.strip, vars_context, strict: true,
        host_context: JinjaHostContext.new(vars_context)
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
    # tier instead, below play vars - matching real Ansible's own
    # precedence for the two cases instead of treating every
    # ansible_facts-returning module like set_fact.
    private def resolve_first_found(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      candidates = task.loop_first_found
      return nil unless candidates

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

      candidates.each do |raw|
        # SCALAR string form (`with_first_found: "{{ undefined_var }}"`):
        # strict - round174 matrix scenario 5b: the keyword's own value is
        # one bare template reference, real Ansible templates it strictly
        # and fails the task ("'undefined_var' is undefined"), not silently
        # skip. Only a BARE/dotted `{{ }}` span raises (see
        # VarSubstitutor#raise_if_strict_undefined) - an ordinary literal
        # candidate string (no templating at all, the overwhelming common
        # case) or one with a filter chain is unaffected.
        #
        # LIST/dict form: lenient (strict omitted). Verified live against
        # ansible-core 2.19.4 (pluggero.upgrade round 601548): real Ansible
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
      # task.loop_first_found_skip) is the only thing that makes real
      # Ansible tolerate a miss - it returns [] so callers skip. Without
      # skip:, real Ansible's first_found lookup RAISES and the task
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
      raise FirstFoundLookupError.new(
        "The lookup plugin 'first_found' failed: No file was found when using first_found."
      ) unless task.loop_first_found_skip?
      [] of JSON::Any
    end

    # with_first_found: and include_vars: resolve relative paths against
    # *different* directories, verified against ansible-core 2.19.4 rather
    # than assumed - conflating them would silently load files real
    # Ansible would not:
    #
    # - the first_found lookup searches the role's `files/` (a probe role
    #   with the same filename in both vars/ and files/ resolved to the
    #   files/ copy, and a name present only in vars/ was skipped);
    # - include_vars: itself searches the role's `vars/`, which is the
    #   whole point of that directory.
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
      return File.exists?(candidate) ? candidate : nil if candidate.starts_with?("/")

      # An explicit paths: sub-key (the dict form's own `- files: [...]
      # paths: [...]`) names the ONLY directories real Ansible searches -
      # found via arillso.authorized_key's own `paths: ['distribution']`,
      # a custom, non-standard directory name outside the hardcoded roots
      # below. A relative entry resolves against the role root (real
      # Ansible's own behavior for with_first_found:'s paths:), an
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
      # apt-key/apt-repo setup real Ansible attempts.
      if custom_paths = task.loop_first_found_paths
        # A relative custom path resolves against the directory of the
        # FILE the with_first_found: task is itself written in - real
        # Ansible's own actual behavior (verified live against
        # ansible-core 2.19.4/2.19.12: `paths: ["distribution"]` on a
        # with_first_found: task living in a role's tasks/main.yml
        # resolved to roles/<role>/tasks/distribution/, not
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
        # was never itself verified and turned out wrong. Tries the
        # including file's own directory FIRST (matching what real
        # Ansible showed), then falls back to the role root and the
        # general per-task include_file_dir, so the earlier
        # role-root-relative case still resolves too.
        including_file_dir = task.include_file_dir || task.role_path.try { |role_dir| File.join(role_dir, "tasks") }

        roots = custom_paths.flat_map do |path|
          rendered = substitutor.substitute(path).strip
          if rendered.starts_with?("/")
            [rendered]
          else
            [including_file_dir, task.role_path].compact.uniq!.map { |anchor| File.join(anchor, rendered) }
          end
        end
        return first_existing(roots, candidate)
      end

      roots = [] of String
      if task.include_vars?
        # include_vars: + with_first_found: (round 812001, mircomasa.
        # filebeat): real Ansible's include_vars action plugin searches the
        # role's vars/ dir FIRST and its tasks/ dir only as a fallback, and
        # never files/ or templates/ (verified live against ansible-core
        # 2.19.11 with a probe role holding the same basename in every
        # subdir: the vars/ copy won; with vars/ empty and only files//
        # templates/ populated, the lookup exhausted and failed). The
        # previous root order here put tasks/ first, so a role shipping the
        # same OS filename in both tasks/ (a task LIST, mircomasa.filebeat's
        # own tasks/Linux.yml) and vars/ (a vars MAPPING, its vars/Linux.yml
        # defining a `default:` dict) resolved the include_vars: to the
        # tasks/ copy, merged zero variables, and every later default that
        # referenced one of them - fb_home: '{{ default["fb_home"] }}' -
        # failed with "'default[...]' is undefined" at the first task that
        # rendered it, even though the include_vars: task itself had
        # reported ok. The tasks/ fallback stays because so5.ssh_hostbased_
        # auth and so5.pbspro (both verified live against ansible-core
        # 2.19.x) include_vars: with_first_found: a "setup-<OS>.yml" idiom
        # whose only matching file lives under tasks/ (never vars/ or
        # files/) - real Ansible resolved to tasks/setup-Debian.yml there.
        task.role_vars_dir.try { |dir| roots << dir }
        task.include_file_dir.try { |dir| roots << dir }
        task.role_path.try { |role_dir| roots << File.join(role_dir, "tasks") }
      else
        # The directory of the file the with_first_found: task itself is
        # written in - real Ansible tries a bare candidate against the
        # task's own file first. include_file_dir is only assigned for
        # include_tasks: statements, though, so a task declared directly
        # in a role's tasks/main.yml has it nil - fall back to the role's
        # tasks/ dir itself.
        task.include_file_dir.try { |dir| roots << dir }
        task.role_path.try { |role_dir| roots << File.join(role_dir, "tasks") }
        unless task.include_tasks?
          task.role_files_dir.try { |dir| roots << dir }
          task.role_templates_dir.try { |dir| roots << dir }
          task.role_vars_dir.try { |dir| roots << dir }
        end
      end
      # vars//files//templates/ are NOT searched for an include_tasks:'
      # with_first_found: at all - include_tasks: consumes task-list YAML
      # only, and real Ansible (verified live against ansible-core 2.19.x
      # with ccdc.ntp_configuration's "Set up NTP time synchronisation"
      # repro) skips straight past an "Debian.yml" candidate even when
      # vars/Debian.yml exists, resolving instead to tasks/Linux.yml.
      # Searching vars/ here matched the candidate against a vars MAPPING
      # and failed the task with "Included tasks file must be a YAML
      # list" - a vars file can never be a valid include target, so
      # including these subdirs for include_tasks: can only ever find a
      # file real Ansible would never pick.
      task.role_path.try { |dir| roots << dir }
      roots << Dir.current

      first_existing(roots, candidate)
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
        # value that evaluates to a LIST of patterns, real Ansible's own
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
            parsed.each { |item| matches.concat(Dir.glob(fileglob_pattern(task, item.to_s))) }
            next
          end
        end

        matches.concat(Dir.glob(fileglob_pattern(task, substituted)))
      end

      matches.sort!
      matches.map { |path| JSON::Any.new(path) }
    end

    # Real Ansible's own fileglob lookup plugin dwims each pattern's
    # directory part relative to the role's files/ dir (path_dwim_relative
    # with 'files'), so a BARE pattern (`*.yml`, no "/" in it) inside a role
    # matches the role's own files/ contents - NOT whatever the process
    # happens to have as its current working directory. Without this, the
    # bare pattern globbed cwd directly: a playbook `site.yml` sitting next
    # to the invocation matched itself instead of the role's
    # middleware.yml/redirect.yml (mismatch-traefik round repro, confirmed
    # live against real ansible-playbook, which found only the role's own
    # files). The returned paths stay the FULL resolved paths Dir.glob
    # yields - the same shape copy:'s src: already receives from
    # resolve_script_path, which leaves an absolute item path untouched
    # (File.join with an absolute candidate just can't exist, then
    # File.expand_path passes it through), so the item never gets
    # double-resolved. An absolute pattern, or one that already carries a
    # directory component, is left as-is; a task outside any role
    # (role_files_dir nil, only set when the role actually ships a files/
    # dir) keeps the old cwd-relative behavior.
    private def fileglob_pattern(task : Task, pattern : String) : String
      return pattern if pattern.starts_with?('/')
      return pattern unless File.dirname(pattern) == "."
      role_files_dir = task.role_files_dir
      role_files_dir ? File.join(role_files_dir, pattern) : pattern
    end

    # Resolve with_file: entries (if any) - real Ansible's `file` lookup
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
      # value must resolve to a 'list', not 'str'" - real Ansible
      # resolves the ternary to the actual list and iterates it fine.
      if current && (raw = current.raw).is_a?(String) && (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#"))
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
        # 'list', not 'str'" instead of the single-item list real
        # Ansible produces from with_items:'s own scalar-wrapping.
        if raw.includes?("{%") || raw.includes?("{#")
          rendered = VariableSubstitutor::JinjaRenderer.new(vars_context).render(raw)
          current = Krikri.parse_json_or_python_literal(rendered)
        else
          current = evaluate_bare_mustache_preserving_type(raw, vars_context) || begin
            inner = raw.strip
            inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
            rendered = VariableSubstitutor::ExpressionEvaluator.new(vars_context).evaluate(inner)
            Krikri.parse_json_or_python_literal(rendered)
          end
        end
      end

      # current can be `nil` two ways: the top-level var (parts[0]) is
      # missing from vars_context entirely, OR it IS present but a later
      # dotted segment (`some_dict.missing_key`) isn't. Both are
      # "undefined" for strictness purposes. An EXPLICITLY-set `null`
      # value (`vars_context[parts[0]]?` returning a JSON::Any wrapping
      # Nil, not Crystal nil) does NOT hit this branch - see bump-2's
      # list-type check in resolve_loop_template for what real Ansible
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
    # bumped here. Real Ansible counts a looped task once in the recap, not
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
    # which caught it. Real Ansible degrades to one clean failed task
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
    # `failed=1`, not `skipped=1`, in the recap - matching real
    # Ansible's own "One or more items failed"); a bare `meta:`/
    # `include_vars:`/batch-group-member check that has no such result
    # pipeline falls back to `swallow_when_error`, which replicates
    # exactly what this method used to do inline (stats/halt/register/
    # print, respecting `ignore_errors:`) and returns `false` - reusing
    # the same "don't run this task" signal every caller already treats
    # a when:-skip as.
    class WhenEvaluationError < Exception
    end

    # Shared substitute+evaluate+strict-undefined-rescue sequence for a
    # when: condition - the one place that owns `raise_undefined: true`
    # (real Ansible's strict-undefined case for when:, see
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
        substitutor = VarSubstitutor.new(vars: vars, host_name: "")
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

    private def resolve_task_become(task : Task, substitutor : VarSubstitutor) : Bool
      expr = task.become_expr
      return task.become? unless expr

      rendered = substitutor.substitute(expr)
      ConditionalEvaluator.evaluate(rendered, {} of String => JSON::Any) rescue task.become?
    end

    # Runtime resolution of a templated `ignore_errors:` (Task#
    # ignore_errors_expr, parsed alongside the eager fallback guess in
    # PlaybookParser.parse_ignore_errors). Mirrors resolve_task_check_mode
    # above: the parse-time guess defaults templated values to TRUE,
    # which is exactly backwards for the idiom's dominant real-world form
    # `ignore_errors: "{{ ansible_check_mode }}"` (= ignore only in check
    # mode) - on a normal run every failure on such a task was silently
    # ignored, the host never halted, and the play kept running where
    # real Ansible had already stopped it (dj-wasabi.telegraf, round
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
    private def resolve_task_ignore_errors(task : Task, vars_context : Hash(String, JSON::Any)? = nil) : Bool
      expr = task.ignore_errors_expr
      return task.ignore_errors? unless expr

      vars = vars_context || {"ansible_check_mode" => JSON::Any.new(@check_mode)} of String => JSON::Any
      substitutor = VarSubstitutor.new(vars: vars, host_name: "")
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
    # value - masking real errors from anyone debugging a failure.
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
      substitutor = VarSubstitutor.new(vars: vars, host_name: "")
      rendered = substitutor.substitute(expr)
      return task.no_log? if rendered == "undefined"
      ConditionalEvaluator.evaluate(rendered, vars) rescue task.no_log?
    end

    private def substitute_task_params(
      params : Hash(String, String),
      substitutor : VarSubstitutor,
      native_containers : Bool = false,
      module_name : String? = nil,
    ) : Hash(String, String)
      result = Hash(String, String).new

      params.each do |key, value|
        # Dynamic variable names - `set_fact: "{{ item.key }}": "{{ item.value }}"`
        # - carry a template in the *key*, not just the value. Real Ansible
        # (and dev-sec os_hardening's "Set OS dependent variables", which
        # builds os_* vars exactly this way) substitutes the key too, so a
        # role can name facts from a loop item's fields. Substituting only
        # the value used to register the fact under the literal key
        # `{{ item.key }}`, making `{{ auditd_package }}` resolve undefined
        # in the next task.
        # strict: true - real Ansible's module-arg templating is
        # strict-undefined by default and raises when a `{{ }}` span
        # references a genuinely undefined variable, failing the task
        # ("Finalization of task args ... failed"). See
        # UndefinedVariableError's own comment for the narrow, bare-
        # reference-only scope of what actually raises here.
        # output: a module argument is final text (see
        # VarSubstitutor#substitute), so a container inside MIXED text
        # renders the way real Ansible renders one (Python repr,
        # live-verified: `msg: "pre {{ list }} post"` prints
        # "pre ['a', 'b'] post"). EXCEPT for a param whose ENTIRE value
        # is one bare `{{ }}` span: real Ansible's native typing keeps
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
        # plain strings in real Ansible, live-verified - the latter via
        # HanXHX.debian_bootstrap) into containers real Ansible never
        # had.
        # set_fact (native_containers) keeps output:false for ALL its
        # params: real Ansible keeps a set_fact: value NATIVELY typed -
        # a container expression stays a real dict/list, not display
        # text. Formatting it as output text here produced a
        # Python-repr STRING fact (buluma.ara_api's own
        # `ara_api_configuration: "{{ {ara_api_env: reconciled_configuration} }}"`
        # became the literal `{'default': {...}}` text, which its own
        # to_nice_yaml then quoted as a scalar and the app failed to
        # parse, round 190).
        stripped_value = value.strip
        whole_single_span = stripped_value.starts_with?("{{") && stripped_value.ends_with?("}}") && stripped_value.scan("{{").size == 1
        substituted_value = substitutor.substitute(value, strict: true, output: !whole_single_span && !native_containers, native: native_containers)

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
        # Python None both render as "", yet real Ansible keeps the two
        # natively apart and its own module argspecs treat them
        # differently - an explicit None fails every `type: list` param
        # with the generic NoneType-conversion message while an empty
        # string (and an omitted param) coerce to an empty list just fine
        # (live-verified against ansible-core 2.19.11 for all four of
        # yum/dnf's `type: list` params). Found via round 900905
        # officel.httpd: every loop item's `enablerepo: ~` default made
        # real ansible-playbook fail the task while this engine installed
        # the packages anyway. The hand-rolled FilterEngine's
        # nil-as-undefined collapse hides the None behind
        # `item.enablerepo | default('')` (real Jinja2's default filter
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

        # `mode:` piped through a variable (`mode: "{{ redis_conf_mode
        # }}"`, geerlingguy.redis's own style) loses its octal-ness the
        # same way a *direct* unquoted `mode: 0770` literal does (see
        # playbook_parser.cr's own #parse_task_params octal-mode comment)
        # - Crystal's YAML parser already decimal-converted the variable's
        # defining `redis_conf_mode: 0640` at vars-file parse time,
        # so #substitute above just stringifies that decimal (Int64 416)
        # as "416" verbatim. Real Ansible's own file module hits the
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
        # all (see plugins/set_fact.cr - real Ansible's native typing
        # keeps a string-sourced fact a string), so every Int64 arriving
        # here is a genuine YAML-octal-derived int and to_s(8) always
        # round-trips the original octal digits.
        if key == "mode"
          stripped = value.strip
          if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
            native = VariableSubstitutor::VariableLookup.new(substitutor.vars).resolve(stripped[2..-3].strip)
            if native && (raw = native.raw).is_a?(Int64)
              substituted_value = raw.to_s(8).rjust(4, '0')
            end
          end
        end

        # `{{ ... | default(omit) }}` (real Ansible's magic variable for
        # dropping a parameter entirely rather than giving it any real
        # value - see OMIT_SENTINEL) - skip the key altogether instead of
        # sending the plugin a literal sentinel string as the param value.
        next if substituted_value == OMIT_SENTINEL

        # An omit that is only PART of a larger value cannot drop the
        # parameter - real Ansible renders it as nothing and keeps the
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

      # Real Ansible parses a command:/shell:'s trailing `creates=`/
      # `removes=`/`chdir=`/`executable=` specials from the module args
      # AFTER templating, not before - this engine's parse-time pass
      # (PlaybookParser.extract_command_special_params) runs on the RAW
      # text, so it silently missed the shape where the whole command is
      # a `{% if %}...{% endif %}` block (found live via kamaln7.
      # swapfile): the raw text's last token there is the literal
      # `{% endif %}` tag, the `creates=...` sits inside one branch, and
      # the strip never fired - so `creates=...` reached `fallocate` as
      # a literal positional argument ("unexpected number of arguments").
      # Real Ansible renders the whole block FIRST (resolving to one
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

      result
    end

    # The msg real Ansible produces when a task-arg templating failure
    # (strict-undefined during module-arg finalization) fails the task -
    # NOT the bare inner error text. Real wraps every
    # AnsibleUndefinedVariable with "The task includes an option with an
    # undefined variable. The error was: <text>. <text>" (the doubled
    # copy is real's own message+orig_exc concatenation), then appends
    # its AnsibleError-obj context: the offending task's source location
    # from the playbook YAML and the surrounding lines with a caret.
    # Live-captured from real ansible-core 2.14 (podman-diff
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
    # else falls back to free-form k=v parsing - real Ansible's own
    # post-template dispatch for a string args value. The sentinel key
    # never reaches the plugin (every plugin's validation now ignores
    # `_`-prefixed keys anyway).
    private def expand_templated_args(params : Hash(String, String)) : Hash(String, String)
      raw = params.delete("_templated_args") || return params
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

    # playbook file for its `- name:` line (or its module key line when
    # nameless) - tasks defined in role/include files report the
    # playbook file's block only when that search happens to find them,
    # and otherwise get the prefix without the context. Non-undefined
    # errors (lookup failures etc.) and already-wrapped environment:/
    # name: keyword errors keep their own real-verified wording.
    private def finalize_args_failure_message(ex : Exception, task : Task) : String
      msg = ex.message || "Failed to resolve task arguments"
      return msg unless ex.is_a?(UndefinedVariableError)
      return msg if msg.starts_with?("Error processing keyword") || msg.starts_with?("Task failed:")

      base = "The task includes an option with an undefined variable. The error was: #{msg}. #{msg}"
      base + task_arg_error_context(task)
    end

    private def task_arg_error_context(task : Task) : String
      path = @playbook_file
      return "" unless path && File.file?(path)

      lines = File.read_lines(path)
      target_idx = nil
      lines.each_with_index do |line, idx|
        stripped = line.strip
        if (name_match = stripped.match(/\A-\s*name:\s*(.+)\z/)) &&
           name_match[1].strip.gsub(/\A["']|["']\z/, "") == task.name
          target_idx = idx
          break
        end
      end
      unless target_idx
        # Nameless task: real points at the module-key line the same way
        # ("    - <module>:"), first key column of the task's mapping.
        lines.each_with_index do |line, idx|
          if line.strip == "- #{task.module_name}:"
            target_idx = idx
            break
          end
        end
      end
      return "" unless target_idx

      target_line = lines[target_idx].chomp
      column = target_line.size - target_line.lstrip.size + 3
      prev_line = target_idx > 0 ? lines[target_idx - 1].chomp : nil

      String.build do |io|
        io << "\n\nThe error appears to be in '" << File.expand_path(path) << "': line " << (target_idx + 1)
        io << ", column " << column << ", but may\nbe elsewhere in the file depending on the exact syntax problem."
        io << "\n\nThe offending line appears to be:\n\n"
        io << prev_line << "\n" if prev_line
        io << target_line << "\n"
        io << (" " * (column - 1)) << "^ here\n"
      end
    end

    # environment: - strict-undefined substitution for both accepted
    # forms, meant to run inside the same protected "finalization of task
    # args" block as substitute_task_params so a referenced-but-undefined
    # variable FAILS the task (real Ansible: "Error processing keyword
    # 'environment': 'proxy_env' is undefined") instead of rendering the
    # lenient "undefined" sentinel into an env var, ryandaniels.
    # server_update_reboot round 300094. Dict form: keys and values are
    # each templated strictly (real Ansible templates the keyword's whole
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
          native = if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
                     VariableSubstitutor::VariableLookup.new(substitutor.vars).resolve(stripped[2..-3].strip)
                   end

          resolved_object = native.try(&.as_h?)
          unless resolved_object
            rendered = native ? native.to_s : substitutor.substitute(raw, strict: true)
            parsed = JSON.parse(rendered)
            object = parsed.as_h?
            # Real Ansible never fails a task over a non-dict environment
            # value - it just warns "could not parse environment value,
            # skipping" and treats the environment as empty. The common
            # trigger is a role default like `proxy_env: []`, meant to be
            # overridden by the caller with a real dict but left as an
            # empty list otherwise (ryandaniels.connectivity_test round
            # 601446: the whole package: task failed here in krikri while
            # real ansible-playbook just installed the packages with no
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
    # above produces: real ansible-core 2.19 fails the child task with
    # "Task failed: Error processing keyword 'name': 'container_name' is
    # undefined" when the block name's chain bottoms out at a variable
    # set nowhere (round 813203, ikke_t.podman_container_systemd run
    # without grafana_podman's `container_name` above it - this engine
    # rendered the block name leniently for display and kept executing
    # deep into the role, diverging on every counter after). The strict
    # substitute reports the INNERMOST missing name (see
    # #raise_if_nested_value_undefined), matching real Ansible. Only
    # fires when the child actually goes to run: real Ansible finalizes
    # the block name after the child's own `when:` passes, so a
    # when-skipped child sails through and the failure lands on the next
    # child that runs (live-verified against 2.19.11). A task's OWN name
    # stays lenient - real Ansible banners it as "<< error 1 - 'nope' is
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

    # For copy:/template:/assemble: tasks that came from a role, a
    # relative src: resolves against the role's files/ or templates/
    # directory - the plugin subprocess itself has no concept of roles, so
    # this has to happen here, before the config is handed off. An
    # absolute src: (or a task not from a role) is left untouched.
    private def resolve_script_path(local_path : String, task : Task) : String?
      if role_dir = task.role_files_dir
        candidate = File.join(role_dir, local_path)
        return File.expand_path(candidate) if File.exists?(candidate)
      end
      # Real Ansible's script action plugin resolves the src against the
      # playbook's own basedir too (`files/` next to the playbook being
      # the common layout) - not just a role's files/ dir and the
      # controller's cwd. Running krikri-playbook from anywhere other
      # than the playbook's own directory left a playbook-relative
      # `files/...` src unresolvable ("the script files/m4-script.sh
      # does not exist on the target (transfer failed?)") where real
      # ansible-playbook found it (found live via modules_systems.yml).
      candidate = File.join(@playbook_dir, local_path)
      return File.expand_path(candidate) if File.exists?(candidate)
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
