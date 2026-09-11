require "./executor"

module Krikri
  class TaskExecutor
    private def notify_handlers(task : Task, host : Host, notify_list : Array(String)) : Nil
      return if notify_list.empty?

      unless notify_list.any?(&.includes?("{{"))
        notify_list.each do |handler_name|
          raise_unless_handler_exists(handler_name, task, host)
          @handler_runner.notify(host, handler_name)
        end
        return
      end

      vars_context = build_vars_context(task, host)
      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      notify_list.each do |handler_name|
        # A `notify: "{{ some_list_var }}"` whose ENTIRE value is one
        # pure `{{ }}` span can itself resolve to a real LIST of
        # handler names, not just a single name - real Ansible notifies
        # every element (and, for an EMPTY list, notifies nothing at
        # all - no error). Verified live against ansible-core 2.19.12.
        # #substitute always flattens to one STRING (Crinja's own
        # repr for an empty list is the literal text "[]"), which used
        # to be treated as a single handler literally NAMED "[]" -
        # found via ome.ice's own dependency role ome.deploy_archive,
        # whose `notify: "{{ deploy_archive_notifies }}"` (default: an
        # empty list) crashed the whole run with "The requested
        # handler '[]' was not found" instead of silently notifying
        # nothing.
        stripped = handler_name.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}")
          structural = begin
            VariableSubstitutor::CrinjaRenderer.new(vars_context).evaluate_value!(stripped[2..-3].strip)
          rescue
            nil
          end
          if structural && (list = structural.as_a?)
            list.each do |item|
              name = item.as_s? || item.to_s
              raise_unless_handler_exists(name, task, host)
              @handler_runner.notify(host, name)
            end
            next
          end
        end

        rendered = handler_name.includes?("{{") ? (substitutor.substitute(handler_name) rescue handler_name) : handler_name
        raise_unless_handler_exists(rendered, task, host)
        @handler_runner.notify(host, rendered)
      end
    end

    # Batching-only, deliberately narrower than #handler_answers_to?:
    # true ONLY when this task's notify: is CERTAIN to abort the run - a
    # literal (untemplated) name that no handler's literal name or
    # listen: topic answers to, with no templated handler name/topic in
    # the play that might still turn out to match at flush time. Anything
    # uncertain answers false and keeps its batching, so the ordinary
    # case pays nothing. See TaskBatcher.plan's *aborts_on_notify*
    # comment for why the batch has to end here.
    private def certainly_aborts_on_notify?(task : Task) : Bool
      notify_list = task.notify
      return false if notify_list.nil? || notify_list.empty?

      handlers = @handler_runner.handlers
      answerable = Set(String).new
      handlers.each do |handler|
        return false if handler.name.includes?("{{")
        answerable << handler.name
        if listen_topic = handler.listen
          return false if listen_topic.includes?("{{")
          answerable << listen_topic
        end
      end

      notify_list.any? do |notify_name|
        next false if notify_name.includes?("{{")
        bare_name = (idx = notify_name.rindex(" : ")) ? notify_name[(idx + 3)..] : notify_name
        !answerable.includes?(notify_name) && !answerable.includes?(bare_name)
      end
    end

    # Real Ansible aborts the run the moment a task notifies a name no
    # handler answers to - see `HandlerNotFoundError`'s own comment for
    # why this lives here (run time, only for a notification actually
    # fired) rather than in a parse-time sweep, and for exactly what
    # real ansible-core 2.19.4 does in each case.
    #
    # The "does anything answer to this name" test deliberately mirrors
    # `HandlerRunner#should_run_handler?` rather than re-deriving its
    # own rules: whatever that method would MATCH must not be rejected
    # here, or a notification this engine can genuinely dispatch would
    # abort the run instead. That includes the role-qualified
    # "<qualifier> : <name>" form (matched on the bare name after the
    # last " : ") and a handler whose own `name:`/`listen:` is itself a
    # template - the latter is rendered against this task's own vars
    # context before comparing, and, failing that, treated as a
    # possible match rather than a miss, since its real per-host value
    # is not known until the flush.
    private def raise_unless_handler_exists(notify_name : String, task : Task, host : Host) : Nil
      return if handler_answers_to?(notify_name, task, host)

      raise HandlerNotFoundError.new(
        "The requested handler '#{notify_name}' was not found in either the main handlers list nor in the listening handlers list"
      )
    end

    private def handler_answers_to?(notify_name : String, task : Task, host : Host) : Bool
      bare_name = (idx = notify_name.rindex(" : ")) ? notify_name[(idx + 3)..] : notify_name

      templated = false
      @handler_runner.handlers.each do |handler|
        candidates = [handler.name]
        if listen_topic = handler.listen
          candidates << listen_topic
        end

        candidates.each do |candidate|
          if candidate.includes?("{{")
            templated = true
            next
          end
          return true if candidate == notify_name || candidate == bare_name
        end
      end

      return false unless templated

      # Only pay for rendering when a raw comparison already missed AND
      # some handler name/topic is a template.
      substitutor = VarSubstitutor.new(vars: build_vars_context(task, host), host_name: host.name)
      @handler_runner.handlers.each do |handler|
        candidates = [handler.name]
        if listen_topic = handler.listen
          candidates << listen_topic
        end

        candidates.each do |candidate|
          next unless candidate.includes?("{{")
          rendered = (substitutor.substitute(candidate) rescue nil)
          # An unrenderable handler name is treated as a possible match,
          # not a miss - its real value depends on vars this task's own
          # context may not carry.
          return true if rendered.nil? || rendered.includes?("{{")
          return true if rendered == notify_name || rendered == bare_name
        end
      end

      false
    end

    # Build the base variable context (play/host/registered/task vars + facts)
    # shared by every execution path for a task.
    # Resolves and parses this play's vars_files for *host*. Cached per
    # host: the paths can be templated against that host's facts, but
    # they do not change between tasks, and re-reading a YAML file for
    # every task on every host would be pure waste.
    @vars_files_cache = Hash(String, Hash(String, JSON::Any)).new

    private def flatten_handler_blocks(handlers : Array(Task)) : Array(Task)
      handlers.flat_map do |handler|
        next [handler] unless handler.block?

        children = handler.block_tasks || [] of Task
        propagate_role_context(handler, children)
        if when_condition = handler.when_condition
          inherit_when_condition(when_condition, handler.when_condition_list, children)
        end

        flatten_handler_blocks(children)
      end
    end

    private def run_handlers : Nil
      # Create callback for handler execution
      # This allows HandlerRunner to execute handlers without duplicating logic
      execute_callback = ->(handler : Task, host : Host) : JSON::Any {
        execute_handler_internal(handler, host)
      }
      name_resolver = ->(handler : Task, host : Host) : String {
        render_task_name_for_display(handler, host)
      }

      # Passing nil instead of @halted_hosts is what --force-handlers
      # means: HandlerRunner skips a notified handler for any host in
      # that set, so withholding it lets a failed host still flush its
      # handlers. Real Ansible keeps failed=1 and rc=2 either way - the
      # flag only decides whether the handler runs.
      @handler_runner.run(execute_callback, @results, @diff_mode, name_resolver,
        @force_handlers ? nil : @halted_hosts)
    end

    # Execute a handler (internal - called via callback)
    private def execute_handler_internal(handler : Task, host : Host) : JSON::Any
      # Build variable context. This used to hand-reassemble the ladder
      # from VariableContext.build + patch-ins for included_vars/role
      # magic vars/facts/hostvars/groups/play-host magic/connection -
      # a second, drift-prone copy of #build_vars_context (every one of
      # those patch-ins carried a "mirroring #build_vars_context" note
      # as its only guarantee of staying in sync). Route handlers
      # through the SAME builder regular tasks use: it is a strict
      # superset of what was assembled here (it additionally provides
      # inventory_hostname/group_names/role defaults+vars
      # tiers/vars_files/extra_vars/remote_user/ansible_host and the
      # "vars" self-view, which handlers never saw), preserves the
      # identical set_fact-vs-ordinary-facts precedence (base_context_
      # a_for's low tier + base_context_b_for's high tier), and benefits
      # from the same per-host base caches.
      vars_context = build_vars_context(handler, host)

      # The handler's own when: is now checked inside #execute_handler_
      # plugin_once instead of here - see that method's own comment for
      # why: checking it here, before loop resolution, evaluated it with
      # NO `item` bound at all, which mattered for a LOOPED handler whose
      # own when: references `item` (e.g. geerlingguy.ssh-chroot-jail's
      # own "add binary libs via l2chroot" handler: `when: item.l2chroot
      # is not defined or item.l2chroot`). Deferring to per-item
      # evaluation there covers both the looped and non-looped case
      # identically (the non-looped call there gets a vars_context with
      # no `item` either, same as before).

      # loop:/with_*: on a handler (e.g. linux-system-roles' journald
      # role: `loop: "{{ __journald_services }}"`, restarting each
      # service in a role-vars list) - previously entirely unhandled
      # here, so a looped handler ran its module exactly once with
      # `item` undefined instead of once per item ("Failed to restart
      # undefined.service: Unit undefined.service not found."). Mirrors
      # the essential semantics of the regular-task loop path
      # (execute_looped_task/finish_looped_task) without reusing it
      # directly - that path is wired into @results/@registered_vars/
      # display bookkeeping specific to the TASK recap, whereas a
      # handler's own accounting already happens in HandlerRunner#run
      # around this method's single return value. Resolves the same
      # loop sources a regular task's own resolution chain does, minus
      # with_fileglob/with_first_found (need a delegate host + shared
      # substitutor a handler has no equivalent concept of, and are
      # vanishingly rare on a handler in practice).
      # resolve_loop_items_or_raise: round174 matrix scenario 10 - a
      # genuinely undefined loop: source fails the handler itself
      # (returned via when_error_result, the same shape execute_handler_
      # plugin_once's own when: WhenEvaluationError rescue already
      # returns - flows through the normal handler result pipeline:
      # halt_if_failed/notify/display below, or execute_handler_loop's
      # per-item aggregation for a looped handler).
      # NB: the failure must NOT early-return here. Everything below this
      # point (halt_if_failed, the handler-notifies-handler forwarding,
      # display/stats) is what makes a failed handler actually mark the
      # run as failed - returning the result directly instead of letting
      # it flow through skipped all of that, so the handler printed its
      # failure and recapped failed=1 while the process still exited 0
      # with a "Playbook execution complete" banner (caught by
      # when_strict_undefined_five_sites_spec.cr's handler example).
      loop_items = nil
      when_error = nil
      begin
        loop_items = resolve_loop_items_or_raise(handler, host, vars_context) do
          handler.loop_items ||
            resolve_loop_template(handler, vars_context) ||
            resolve_loop_nested(handler, vars_context, host.name) ||
            resolve_loop_flattened(handler, vars_context, host.name) ||
            resolve_loop_subelements(handler, vars_context) ||
            resolve_loop_filetree(handler, host, vars_context)
        end
      rescue ex : WhenEvaluationError
        when_error = ex
      end

      result = if ex = when_error
                 when_error_result(ex)
               elsif items = loop_items
                 execute_handler_loop(handler, host, vars_context, items)
               else
                 execute_handler_plugin_once(handler, host, vars_context)
               end

      # A handler can itself notify: further handlers (robertdebock.
      # auditd's own "Run augenrules" -> notify: "Load rules" -> real
      # Ansible runs "Load rules" within the SAME flush_handlers pass,
      # since HandlerRunner#run's @handlers.each iterates in definition
      # order and "Load rules" is defined after "Run augenrules" - by
      # the time the loop reaches it, this notify call has already
      # landed in @notified_handlers and should_run_handler? picks it
      # up naturally, no restructuring of #run needed. Previously
      # entirely unhandled - only a regular TASK's own notify: was ever
      # forwarded to HandlerRunner, so a handler-to-handler notify
      # silently dropped the second handler ("Load rules" never ran,
      # `augenrules --load` never re-applied the just-regenerated
      # rules).
      changed = result["changed"]?.try(&.as_bool) == true
      if changed && (notify_list = handler.notify)
        notify_handlers(handler, host, notify_list)
      end

      # A failed handler halts the rest of the play for this host, same
      # as a failed regular task (real Ansible: an unrescued handler
      # failure aborts the host's play run) - every other execution path
      # in this file (execute_looped_task, execute_include_tasks, the
      # plain-task path, etc.) calls halt_if_failed, but this one never
      # did. robertdebock.unbound's own `./configure --enable-systemd`
      # handler genuinely fails on stock Ubuntu 22.04 (libsystemd-dev
      # not installed - a real external role/environment gap, reproduces
      # on real ansible-playbook too, which correctly stops right there)
      # - krikri-playbook instead kept running every task after the
      # `meta: flush_handlers` that triggered it, diverging from real
      # Ansible's own recap (extra ok:/changed:/failed: entries for
      # tasks real Ansible never even attempted).
      halt_if_failed(handler, host, result["failed"]?.try(&.as_bool) == true) unless resolve_task_ignore_errors(handler)

      result
    end

    # Runs *handler*'s module once per *loop_items* entry (item/loop_var
    # bound in a per-iteration copy of *vars_context*, matching a regular
    # task's own loop binding), printing each item's own result line and
    # returning one aggregate result (changed: true if any item changed,
    # failed: true if any item failed) - HandlerRunner#run's own
    # display/stats step is then a no-op on the boolean summary alone,
    # not a second full display pass, via the `already_displayed` marker.
    private def execute_handler_loop(
      handler : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any),
    ) : JSON::Any
      if handler.loop_items_needs_flatten?
        loop_items = flatten_with_items_one_level(
          loop_items.map { |item| deep_render_item(item, base_vars_context, host.name, strict: false) }
        )
      end
      loop_var = handler.loop_var
      index_var = handler.index_var
      any_changed = false
      any_failed = false

      # An empty loop: source (e.g. cloudalchemy.cortex's "reload cortex
      # services" handler looping over `cortex_services | dict2items`
      # when cortex_all_in_one: leaves that dict empty) skips the whole
      # handler in real Ansible ("All items skipped") rather than running
      # zero times silently - found via a real ok/skipped-count off-by-
      # one against real ansible-playbook. Without this, the handler fell
      # through to the empty loop below, never printed a "skipping:"
      # line, and #record_handler_result's already_displayed branch
      # counted the no-op result as "ok" instead of "skipped".
      if loop_items.empty?
        # Same module-resolution-before-loop-emptiness gap execute_looped_task's
        # own call handles for regular tasks - a handler's module is just as
        # reachable via a fired notify: regardless of what its loop resolves to.
        register_reachable_unavailable_module(handler, base_vars_context, host)
        puts "skipping: [#{host.connection_host}]".colorize(:cyan)
        return JSON.parse({
          "changed" => false,
          "failed"  => false,
          "skipped" => true,
        }.to_json)
      end

      loop_items.each_with_index do |item, idx|
        vars_context = base_vars_context.dup
        vars_context["item"] = item
        vars_context[loop_var] = item if loop_var
        vars_context[index_var] = JSON::Any.new(idx.to_i64) if index_var

        result = execute_handler_plugin_once(handler, host, vars_context)
        next if result["skipped"]?.try(&.as_bool)

        any_changed ||= result["changed"]?.try(&.as_bool) || false
        any_failed ||= result["failed"]?.try(&.as_bool) || false
        ResultDisplay.display_result(host, result, @diff_mode, item_label: item_display(item), ignore_errors: resolve_task_ignore_errors(handler, base_vars_context), no_log: resolve_task_no_log(handler, base_vars_context))
      end

      JSON.parse({
        "changed"           => JSON::Any.new(any_changed),
        "failed"            => JSON::Any.new(any_failed),
        "already_displayed" => JSON::Any.new(true),
      }.to_json)
    end

    # The actual single-execution body every handler run (looped or not)
    # goes through - unchanged from before loop: support was added, just
    # extracted so execute_handler_loop can call it once per item.
    private def execute_handler_plugin_once(handler : Task, host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      # An unavailable-module handler (see Task#unavailable_module - a
      # module this engine hasn't implemented, e.g. a role's
      # kubernetes.core.helm_repository handler) skips exactly like a
      # when:-false handler instead of reaching the plugin dispatch
      # below, which has no plugin binary to find and crashed the whole
      # run outright ("Plugin binary not found: <module>", unhandled
      # exception, rc=1, no PLAY RECAP) - the same
      # hard-crash-instead-of-graceful-skip shape the regular-task path
      # guards against in #when_passes? (that guard is why regular
      # unavailable-module tasks skip). Mirrors that guard's one
      # exception too: an unavailable module backed by a role-private
      # `library/<name>.py` source CAN run (PythonModuleRunner), so it
      # falls through to normal dispatch. The handler is recorded into
      # reachable_unavailable_modules (via
      # register_reachable_unavailable_module, which re-evaluates the
      # handler's own when: for the final exit-code decision) so a
      # genuinely-reachable unported module still fails the run's exit
      # code the way every other unavailable module does.
      if handler.unavailable_module && python_module_source_for(handler).nil?
        register_reachable_unavailable_module(handler, vars_context, host)
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
        suffix = (item = vars_context["item"]?) ? " => (item=#{item_display(item)})" : ""
        puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
        return JSON.parse({
          "changed" => false,
          "failed"  => false,
          "skipped" => true,
        }.to_json)
      end

      # Evaluate the handler's own when: here (not in #execute_handler_
      # internal, before loop resolution) - real Ansible skips a
      # notified handler whose condition is false (e.g. os_hardening's
      # "Restart auditd via service" handler is gated on os_family ==
      # 'RedHat'), and for a LOOPED handler, evaluates that condition
      # ONCE PER ITEM with `item` bound, exactly like a regular task's
      # own per-iteration when:. Checking it earlier (before the loop
      # even resolved) meant a per-item condition referencing `item`
      # (`when: item.l2chroot is not defined or item.l2chroot`) always
      # saw an UNBOUND item, so `item.l2chroot is not defined` was
      # trivially true regardless of any individual item's real value -
      # every item ran unconditionally. Found benchmarking round168's
      # geerlingguy.ssh-chroot-jail on Ubuntu 22.04 ("add binary libs via
      # l2chroot" ran l2chroot against /usr/bin/which despite its own
      # `l2chroot: false` flag, which failed since `which` isn't a
      # dynamic executable). A skipped handler is not shown as changed/
      # failed and isn't counted in the recap, matching real Ansible.
      if when_condition = handler.when_condition
        begin
          when_result = evaluate_when_items(handler, vars_context, host)
        rescue ex : WhenEvaluationError
          # Flows through the normal handler result pipeline (#execute_
          # handler's own halt_if_failed/notify/display, or
          # execute_handler_loop's per-item aggregation for a looped
          # handler) exactly like the substitute_task_params rescue just
          # below - same shape when_error_result already builds for
          # execute_task_once.
          return when_error_result(ex)
        end

        unless when_result
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = (item = vars_context["item"]?) ? " => (item=#{item_display(item)})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          return JSON.parse({
            "changed" => false,
            "failed"  => false,
            "skipped" => true,
          }.to_json)
        end
      end

      # include_tasks: on a handler (Anthony25.unbound's own "restart
      # unbound": `include_tasks: tasks/restart_unbound.yml`) - real
      # Ansible lets a handler include a task file exactly like a regular
      # task can, splicing its tasks into the flush_handlers run. This
      # engine only special-cased include_tasks? on the regular-task path
      # (execute_task's own `return execute_include_tasks(task, host) if
      # task.include_tasks?` dispatch) - a handler fell all the way
      # through to the plugin-dispatch code below unconditionally, which
      # tried to upload/run a plugin binary for the synthetic "_include_
      # tasks" pseudo-module name and crashed the whole run outright
      # ("Plugin binary not found: _include_tasks") instead of running
      # the included file's tasks. Mirrors run_include_tasks_once's own
      # file-resolution + parse + run_task_list sequence (the same
      # method the regular-task path already delegates to), minus that
      # method's loop/vars: handling (round174-style handler loops are
      # already resolved one level up in #execute_handler_internal, and
      # a handler's own include_tasks: has no separate loop of its own
      # beyond the handler's).
      if handler.include_tasks?
        path_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        file_rel = path_substitutor.substitute(handler.include_file.as(String))
        resolved_path = PlaybookParser.resolve_include_path(file_rel, handler.include_file_dir.as(String))

        unless File.exists?(resolved_path)
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "Included tasks file not found: #{resolved_path}",
          }.to_json)
        end

        yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
        # A comment-only (or entirely blank) tasks file - see the
        # regular-task include_tasks: path's identical check for why.
        return JSON.parse({"changed" => false, "failed" => false}.to_json) if yaml.raw.nil?
        unless yaml.as_a?
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "Included tasks file must be a YAML list: #{resolved_path}",
          }.to_json)
        end

        inherited = Play.new("", "")
        inherited.become = handler.become?
        inherited.become_user = handler.become_user
        included_tasks = PlaybookParser.parse_tasks(yaml.as_a, inherited, "task in included #{resolved_path}", File.dirname(resolved_path), role_path: handler.role_path, playbook_dir: @playbook_dir)
        propagate_role_context(handler, included_tasks)

        run_task_list(included_tasks, host)

        return JSON.parse({"changed" => false, "failed" => false}.to_json)
      end

      substitutor = VarSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )

      # Substitute variables in handler parameters. Same "finalization of
      # task args failed" rescue as execute_task_once/prepare_batch_step
      # (see there) - a handler has no equivalent before this, so a
      # strict: UndefinedVariableError would have crashed the whole run.
      begin
        substituted_params = substitute_task_params(handler.params, substitutor, native_containers: handler.module_name.ends_with?("set_fact"), module_name: handler.module_name)
        substituted_env = substitute_task_environment(handler, substitutor)
      rescue ex
        result = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => ex.message || "Failed to resolve task arguments",
        }.to_json)
        result = apply_changed_failed_when(handler, result, vars_context, host)
        if register_name = handler.register
          register_result(host, register_name, result) unless register_name.empty?
        end
        return result
      end

      if handler.module_name == "ansible.builtin.reboot"
        result = execute_reboot(substituted_params, host, vars_context, resolve_task_check_mode(handler, vars_context))
        result = apply_changed_failed_when(handler, result, vars_context, host)
        if register_name = handler.register
          register_result(host, register_name, result) unless register_name.empty?
        end
        return result
      end

      # Same role-relative src: resolution + remote staging a regular
      # task's #execute_task_once/#prepare_batch_step already do -
      # previously missing here entirely, so a handler using copy:/
      # template: with a role-relative src: (not just an action-plugin
      # module, see #execute_handler_internal's own doc comment above)
      # would fail identically to the resolve_role_relative_src bug just
      # fixed for regular tasks. Found while auditing that fix, not yet
      # hit by a real role in this round.
      substituted_params = resolve_role_relative_src(handler, substituted_params)
      substituted_params = inline_copy_source_content(handler, substituted_params, host, vars_context)
      substituted_params = stage_unarchive_remote_src(handler, substituted_params, host, vars_context)
      substituted_params = stage_script_src(handler, substituted_params, host, vars_context)
      substituted_params = stage_assemble_dir(handler, substituted_params, host, vars_context)
      substituted_become_user = handler.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      # Real bug found benchmarking geerlingguy.jenkins: its own
      # "configure default users" handler is a template: task
      # (`handlers/main.yml`, not `tasks/`) - unlike #execute_task_once/
      # #prepare_batch_step above, this method never ran a handler's
      # module through ActionPluginManager at all, so template:'s own
      # controller-side render step (reading/rendering the .j2 file
      # locally, then injecting the result as a `content:` param before
      # dispatch) never happened for ANY handler, only regular tasks:.
      # The plugin then ran on the remote host with no `content:` param
      # at all and failed outright - not a silent divergence, every
      # template:/copy:-with-role-src:/etc. handler in a real playbook
      # would hit this identically.
      if ActionPluginManager.has_action_plugin?(handler.module_name)
        action_result = ActionPluginManager.execute_action(
          handler.module_name,
          substituted_params,
          vars_context,
          host
        )

        unless action_result.success?
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
        end

        if final = action_result.final_result
          result = apply_changed_failed_when(handler, final, vars_context, host)
          if register_name = handler.register
            register_result(host, register_name, result) unless register_name.empty?
          end
          return result
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      # Build config for plugin - serialized once, with
      # ansible_connection=local already in the wire payload when this
      # handler runs over SSH (same treatment as execute_task_once).
      wire_vars = vars_context
      if PluginManager.remote_execution?(handler.module_name, host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = build_plugin_config(handler, host, substituted_params, wire_vars, substituted_become_user, substituted_env)

      become = resolve_task_become(handler, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
        end
      end

      result = PluginManager.execute_plugin(
        handler.module_name,
        config,
        host,
        vars_context,
        become,
        become_user
      )

      # A handler's own changed_when:/failed_when:/register: were
      # entirely unapplied - this method just returned the raw plugin
      # result. Same "separate dispatch path from regular tasks, missing
      # a step the regular path already has" pattern already found for
      # handlers using an action-plugin module and handler loops (see
      # this method's own doc comment above, and execute_handler_loop's)
      # - found via geerlingguy.gitlab's own "restart gitlab" handler
      # (`command: gitlab-ctl reconfigure`, `failed_when:
      # gitlab_restart_handler_failed_when | bool`, `register:
      # gitlab_restart`): a real, expected-to-sometimes-fail reconfigure
      # (a known upstream GitLab/role-version incompatibility, not a
      # krikri-playbook bug - confirmed identically failing when run
      # directly on both hosts) always propagated as a genuine task
      # failure, since failed_when could never suppress it here, while
      # real ansible-playbook's own run of the identical role reports
      # this handler as "changed", not failed.
      result = apply_changed_failed_when(handler, result, vars_context, host)

      if register_name = handler.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      result
    end
  end
end
