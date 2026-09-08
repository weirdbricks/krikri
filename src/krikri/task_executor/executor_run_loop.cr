require "./executor"

module Krikri
  class TaskExecutor
    private def run_free_for_host(host : Host) : Nil
      @tasks.each do |task|
        break if @halted_hosts.includes?(host.name)

        buffer = IO::Memory.new
        OutputRouting.redirect_current_fiber_to(buffer)
        begin
          run_task_list([task], host)
        ensure
          OutputRouting.clear_current_fiber_redirect
          print buffer.to_s
        end
      end
    end

    private def free_strategy? : Bool
      strategy = @strategy
      return false unless strategy
      strategy == "free" || strategy == "host_pinned"
    end

    # `strategy: free` - each host runs the WHOLE task list on its own,
    # with no barrier between tasks, so a fast host races ahead while a
    # slow one is still on an earlier task. Verified against ansible-core
    # 2.19.4: with h1 sleeping in task 1, h2 prints its own banner and
    # result for BOTH tasks before h1 reports task 1 at all.
    #
    # Bounded by --forks, like every other fan-out here. Output is NOT
    # buffered per host: real Ansible interleaves these lines as they
    # happen, which is the whole visible point of the strategy.
    private def run_free : Nil
      hosts = @hosts
      return if hosts.empty?

      if hosts.size == 1 || @forks <= 1
        hosts.each { |host| run_free_for_host(host) }
        return
      end

      gate = Channel(Nil).new(Math.min(hosts.size, @forks))
      Math.min(hosts.size, @forks).times { gate.send(nil) }
      done = Channel(Nil).new(hosts.size)

      hosts.each do |host|
        spawn do
          gate.receive
          begin
            run_free_for_host(host)
          ensure
            gate.send(nil)
            done.send(nil)
          end
        end
      end

      hosts.size.times { done.receive }
    end

    # Whether *task* can safely fan out across hosts via --forks. Excluded:
    # run_once: (needs @hosts.first to have actually finished before other
    # hosts can copy its register via copy_run_once_register - a real
    # ordering dependency, not just a data-race concern), block?/
    # include_role? (recurse into their own nested task lists and
    # ensure_grouped calls via run_task_batch - kept serial to sidestep any
    # question of concurrent re-entrancy into the batching planner), and
    # the non-looped include_tasks? case (handled by its own
    # execute_include_tasks_multi path in run_task_batch before this is
    # ever consulted).
    #
    # A *looped* include_tasks: (task_has_loop? true - e.g. robertdebock.
    # users' "Loop over users_groups") IS allowed through here: each host's
    # execute_task -> execute_include_tasks call re-parses its own fresh
    # `included_tasks` Task array (no shared object with any other host's
    # fiber) and only ever touches per-host keys of hashes pre-seeded with
    # every host's key in #initialize - the same safety argument
    # run_task_for_hosts_in_parallel's own docs make for plain tasks. The
    # one shared mutable state a nested run_task_list/ensure_grouped call
    # touches is @task_group/@grouped_lists, keyed by each per-host task
    # list's own object_id, so concurrent hosts never collide on the same
    # key; TaskBatcher.plan itself does no I/O, so a fiber never yields
    # mid-mutation. Before this, a looped include_tasks: ran every whole
    # host's full loop serially before the next host started - the same
    # one-host-at-a-time bug round 37 (0.9.383) fixed for the non-looped
    # case, just never extended to this narrower, rarer shape.
    private def task_forkable?(task : Task) : Bool
      return false if task.run_once?
      return false if task.block?
      return false if task.include_tasks? && !task_has_loop?(task)
      return false if task.include_role?
      true
    end

    # True if *task* has ANY loop source configured (loop:/with_items:/
    # with_dict:/with_fileglob:/with_first_found:/with_flattened:/
    # with_subelements:/etc), regardless of whether it can be resolved
    # yet. Used to keep a looped `include_tasks:` (rare - e.g.
    # robertdebock.users' own "Loop over users_groups") off
    # execute_include_tasks_multi below, which doesn't attempt to thread a
    # per-item `item` binding across a host group - it still goes through
    # execute_include_tasks's own single-host per-iteration loop, just now
    # fanned out across hosts concurrently via task_forkable? instead of
    # one whole host's loop finishing before the next host starts.
    private def step_allows?(task : Task) : Bool
      return true unless CliOptions.step?
      return true if @step_continue

      print "Perform task: TASK: #{task.name} (N)o/(y)es/(c)ontinue: "
      answer = (STDIN.gets || "").strip.downcase

      case answer
      when "c"
        @step_continue = true
        true
      when "y"
        true
      else
        false
      end
    end

    # True once this play should stop for EVERY host. Also records the
    # decision so krikri-playbook.cr can skip the remaining serial: batches
    # - real Ansible does not start the next batch after an abort
    # (verified: `serial: 1` + any_errors_fatal with h2 failing runs h1's
    # batch fully, then stops; h3 never runs at all).
    getter play_aborted : Bool = false

    private def abort_play?(hosts : Array(Host)) : Bool
      return true if @play_aborted
      return false if hosts.empty?

      failed = hosts.count { |host| @halted_hosts.includes?(host.name) }
      return false if failed == 0

      triggered =
        if @any_errors_fatal
          true
        elsif limit = @max_fail_percentage
          # Strictly greater, matching real Ansible.
          (failed * 100.0 / hosts.size) > limit
        else
          false
        end

      return false unless triggered

      @play_aborted = true
      hosts.each { |host| @halted_hosts << host.name }
      true
    end

    # Emits real Ansible's UNREACHABLE! line for *host* and books it as
    # either ignored (ignore_unreachable:) or unreachable, halting the
    # host in the latter case.
    private def run_task_batch(tasks : Array(Task), hosts : Array(Host)) : Nil
      ensure_grouped(tasks)

      tasks.each do |task|
        next unless step_allows?(task)

        # A host known to be unreachable produces an unreachable result
        # for every task, exactly as real Ansible does when the
        # connection keeps failing - and `ignore_unreachable: true`
        # makes that one ignored rather than fatal, letting the host go
        # on to the next task.
        hosts.each do |host|
          next unless @unreachable_hosts.includes?(host.name)
          next if @halted_hosts.includes?(host.name)

          report_unreachable(task, host)
        end

        # any_errors_fatal:/max_fail_percentage: are evaluated BETWEEN
        # tasks: once the threshold is crossed the play stops for every
        # host, not just the ones that failed. Checked here rather than
        # at the end so the very next task is the one that does not run.
        break if abort_play?(hosts)

        # Unreachable hosts are excluded from EXECUTION as well as from
        # the halted set: report_unreachable above has already booked the
        # result, and an ignore_unreachable: host stays un-halted on
        # purpose - without this it would fall through to a real SSH
        # attempt and hang on the connection it is already known to fail.
        # meta: end_role rejections are applied SEPARATELY (below), not
        # folded into this set: a role-ended host recovers for every task
        # outside that role, so it must never trip the all-hosts-done
        # break that a genuinely halted play legitimately ends on.
        halt_rejected = hosts.reject do |host|
          @halted_hosts.includes?(host.name) || @unreachable_hosts.includes?(host.name)
        end

        # Once every host in scope is halted/unreachable, real Ansible ends
        # the play right there rather than continuing to print empty "TASK
        # [...]" banners for the remaining tasks - a host can't become
        # active again within this same task list (only rescue:/always:
        # temporarily un-halt, and those run via their own separate
        # run_task_batch call). Found via geerlingguy.raspberry-pi: a
        # single-host play kept printing banners for every task after its
        # one host failed and halted.
        break if halt_rejected.empty?

        active_hosts = halt_rejected.reject { |host| role_ended_for_host?(task, host) }
        # Every active host had this role ended for it - a fully consumed
        # task prints nothing at all (real Ansible's silent iterator
        # consume), but later tasks outside the role still run.
        next if active_hosts.empty?

        if task.block?
          execute_block_multi(task, active_hosts)
          next
        end

        if task.include_tasks? && !task_has_loop?(task)
          execute_include_tasks_multi(task, active_hosts)
          next
        end

        # The banner prints once per task, not per host - real Ansible's
        # own convention - so a templated name is rendered against
        # whichever host will actually run first (matches this file's
        # existing `run_once`-style "first host" precedent elsewhere).
        # A static import_role: (Task#is_static_import) gets no banner of
        # its own, same as block: above - only the included role's own
        # tasks do (see is_static_import's own comment).
        unless @adhoc || (task.include_role? && task.is_static_import?)
          display_host = active_hosts.first? || hosts.first
          puts "TASK [#{task_role_prefix(task)}#{render_task_name_for_display(task, display_host)}]".colorize(:white).bold
          puts "*" * 70
        end

        if @forks > 1 && task_forkable?(task) && active_hosts.size > 1 && task.throttle != 1 && (task.debugger || @debugger).nil?
          run_task_for_hosts_in_parallel(task, active_hosts)
        else
          active_hosts.each { |host| execute_task(task, host) }
        end

        puts "" unless @adhoc
      end
    end

    # Splits *hosts* by *task*'s own when: (true unless a when: is
    # actually present - matches ConditionalEvaluator's own default).
    # Shared by execute_block_multi and execute_include_tasks_multi,
    # both of which need to separate hosts that skip the whole nested
    # list from ones that actually run it before batching the latter.
    # *inherit_on_error*: a block:'s when: is inherited by its children,
    # so a condition that RAISES must be pushed down and re-raised once
    # per child task rather than failing the block as a unit - see
    # execute_block's own rescue for the live-verified semantics. The
    # include_tasks: caller leaves this false: there, real Ansible fails
    # the single include task itself (verified live, round173), so the
    # swallow path below is already correct for it.
    private def partition_by_when(task : Task, hosts : Array(Host), inherit_on_error : Bool = false) : {Array(Host), Array(Host)}
      return {hosts, [] of Host} unless when_condition = task.when_condition

      run_hosts = [] of Host
      skip_hosts = [] of Host
      hosts.each do |host|
        vars_context = build_vars_context(task, host)
        begin
          if evaluate_when(when_condition, vars_context, host)
            run_hosts << host
          else
            skip_hosts << host
          end
        rescue ex : WhenEvaluationError
          # A raise here only affects THIS host - every other host in
          # *hosts* still gets partitioned normally.
          if inherit_on_error
            inherit_when_condition(when_condition, task.block_tasks)
            inherit_when_condition(when_condition, task.rescue_tasks)
            inherit_when_condition(when_condition, task.always_tasks)
            run_hosts << host
          else
            # Fails cleanly for this one host (stats/halt/register/print
            # via swallow_when_error, respecting its own ignore_errors:).
            # The failed host is excluded from both run_hosts and
            # skip_hosts - it's already been fully accounted for, unlike
            # a genuine skip.
            swallow_when_error(task, host, ex)
          end
        end
      end
      {run_hosts, skip_hosts}
    end

    # Multi-host counterpart to execute_block: batches block_tasks/
    # rescue_tasks/always_tasks across every host in *hosts* at once via
    # run_task_batch, instead of running the whole block one host at a
    # time. Per-host bookkeeping (failed/rescued counts, @halted_hosts)
    # mirrors execute_block's own single-host logic exactly, just driven
    # off host sets instead of one host.
    private def run_task_for_hosts_in_parallel(task : Task, hosts : Array(Host)) : Nil
      # throttle: caps concurrency for this task BELOW --forks - real
      # Ansible's own semantics (it never raises the limit, only lowers
      # it). A throttle of 1 makes the task effectively serial.
      max_parallel = Math.min(hosts.size, @forks)
      max_parallel = Math.min(max_parallel, task.throttle) if task.throttle > 0
      max_parallel = 1 if max_parallel < 1
      pool = ensure_host_worker_pool(hosts)
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      buffers = Hash(String, IO::Memory).new
      done = Channel(String).new(hosts.size)

      hosts.each do |host|
        pool[host.name].send(WorkMessage.new(task, host, buffers, done, gate))
      end

      # Printed as each host FINISHES, not in host order afterwards -
      # real ansible-playbook reports the fast host first when a slower
      # one is still working, and this engine used to hold everything
      # back and then print in inventory order. Each host's output is
      # still flushed as one buffered block, so completion order costs
      # nothing in readability: concurrent hosts still cannot interleave
      # mid-task.
      hosts.size.times do
        finished = done.receive
        if buffer = buffers[finished]?
          print buffer.to_s
        end
      end
    end

    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #22: ensure a
    # persistent worker fiber exists for every host in `hosts`,
    # creating any missing entries in `@host_worker_pool` on demand.
    # Idempotent: callers can invoke this freely without spawning
    # duplicate workers. The worker loop is `receive -> gate.receive ->
    # execute_task -> store result -> signal done -> gate.send`, which
    # preserves the same parallelism-bounded-by-`@forks` semantics the
    # old per-call `spawn` pattern had (gate is consulted per-task, not
    # per-host).
    private def ensure_host_worker_pool(hosts : Array(Host)) : Hash(String, Channel(WorkMessage))
      hosts.each do |host|
        next if @host_worker_pool.has_key?(host.name)
        channel = Channel(WorkMessage).new
        @host_worker_pool[host.name] = channel
        spawn do
          loop do
            msg = channel.receive
            msg.gate.receive
            buffer = IO::Memory.new
            OutputRouting.redirect_current_fiber_to(buffer)
            escaped : Exception? = nil
            begin
              execute_task(msg.task, msg.host)
            rescue ex
              escaped = ex
            ensure
              # The dispatcher blocks on done.receive until this host's
              # name arrives, so the result handoff MUST happen even when
              # execute_task raises - sending outside the ensure turned
              # any escaping exception into a permanent dispatcher hang
              # (the worker fiber died silently and the run never
              # finished).
              OutputRouting.clear_current_fiber_redirect
              msg.results[msg.host.name] = buffer
              msg.done_signal.send(msg.host.name)
              msg.gate.send(nil)
            end
            if ex = escaped
              # The worker is still alive (the ensure above completed the
              # handshake), but its per-task contract was broken by the
              # exception, so retire it - the next ensure_host_worker_pool
              # call respawns a fresh fiber - and let the exception escape
              # as this fiber's uncaught exception, aborting the run the
              # same way the single-host path would.
              @host_worker_pool.delete(msg.host.name)
              raise ex
            end
          end
        end
      end
      @host_worker_pool
    end

    # Gather facts for all hosts using the facts plugin
    # Each host's fact gathering is fully independent - writes only to
    # @facts[host.name] and @results[host.name], both pre-seeded per host
    # in #initialize, so no concurrent hash resizing - so it's gathered
    # in parallel via a bounded pool of fibers, one round trip's worth of
    # wall-clock time overlapping instead of summing across every host.
    # Bounded (not one fiber per host unconditionally) to avoid opening
    # an unbounded number of simultaneous SSH connections against a large
    # inventory. Output is collected per host and printed in deterministic
    # @hosts order only after every fiber has finished, so interleaved
    # completions never scramble the display - this was Stage A of the
    # cross-host parallelism work (`0.9.75`); Stage B, parallelizing the
    # per-task host loop itself via `--forks`, landed separately in
    # `0.9.77`. See git log for both.
    private def execute_task(task : Task, host : Host) : Nil
      # A `meta: end_role` for this host consumes every remaining task of
      # the calling role silently - no banner, no result, no recap
      # counter (real Ansible's iterator peek/consume behavior). The
      # check sits here, the single funnel every task path (top-level
      # loop, blocks, nested include_role/include_tasks lists) goes
      # through, so the run loop's own active_hosts rejection above only
      # exists to keep the banner from printing for fully-consumed tasks.
      return if role_ended_for_host?(task, host)

      return execute_block(task, host) if task.block?
      return execute_include_tasks(task, host) if task.include_tasks?
      return execute_include_role(task, host) if task.include_role?
      if task.meta?
        # `when:` on a meta: task was previously never evaluated at all -
        # latent since meta: shipped (clear_facts/flush_handlers are
        # rarely when:-gated in practice), surfaced adding end_host/
        # end_play, whose whole point is frequently being conditional
        # per host. Verified against real ansible-playbook: a when:-false
        # meta: task prints "skipping: [host]" but - like every other
        # meta: outcome - does NOT bump the recap's skipped= counter
        # (defer_stats: true), unlike an ordinary task's when: skip.
        vars_context = build_vars_context(task, host)
        begin
          execute_meta(task, host) if when_passes?(task, vars_context, host, defer_stats: true)
        rescue ex : WhenEvaluationError
          swallow_when_error(task, host, ex, defer_stats: true)
        end
        return
      end
      return execute_include_vars(task, host) if task.include_vars?
      return execute_validate_argument_spec(task, host) if task.validate_argument_spec?

      # run_once: only ONE host in the play actually executes it; later
      # hosts get no output/stats at all, matching real Ansible - but
      # still pick up whatever it registered, so later tasks on those
      # hosts can reference the same variable. Which host executes is
      # elected on first arrival (the first host to reach this point for
      # this task) rather than pinned to the literal first inventory
      # host - if that host is unreachable/halted the task used to never
      # run anywhere, while real Ansible runs it on the first *active*
      # host. Election is safe under cooperative scheduling: the
      # check-and-set below has no yield point between the read and the
      # write.
      if task.run_once?
        @run_once_elected[task] ||= host.name
        if @run_once_elected[task] != host.name
          copy_run_once_register(task, host)
          return
        end
      end

      # An earlier group member's trigger may have already built this
      # exact context while preparing this task's own batch step
      # (execute_batch_group prepares every member up front) - reuse it
      # instead of paying for VariableContext.build + facts merge again.
      vars_context = @batch_cache[host.name]?.try(&.[task]?).try(&.[1]) ||
                     build_vars_context(task, host)

      # delegate_to: run the module against a different host's connection
      # while vars/facts/register/stats stay attributed to `host` - resolved
      # here (not at parse time) since it may be templated and needs the
      # variable context to substitute against.
      # One substitutor for this (task, host), built only where it will
      # actually be used. The constructor copies the whole vars hash and
      # adds the magic variables, and nothing between here and
      # execute_task_once mutates vars_context (verified for
      # resolve_delegate_host / resolve_fileglob / resolve_loop_template),
      # so the instances this path used to build were copies of an
      # identical thing.
      #
      # Deliberately *not* built unconditionally up front: the loop and
      # until: paths below return before ever reaching execute_task_once
      # and build their own per item / per attempt, so an eager instance
      # here would be pure waste for every looped task - which measured
      # as a real regression when tried that way.
      #
      # apply_changed_failed_when still builds its own, and must: it
      # evaluates against a different context (see there).
      shared_sub = nil.as(VarSubstitutor?)
      if task.delegate_to || task.loop_fileglob || task.loop_file
        shared_sub = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      end

      exec_host = resolve_delegate_host(task, host, vars_context, shared: shared_sub)

      # with_fileglob/with_file need a substitutor (for {{ vars }} in the
      # pattern) and the filesystem, so they can only be resolved here,
      # not at parse time. loop_template is a loop:/with_*: keyword given
      # as "{{ some_var }}" instead of a literal list/dict - also only
      # resolvable once the variable context exists.
      #
      # resolve_loop_items_or_raise: a genuinely undefined/wrong-type loop
      # source now fails the task (round174 matrix) instead of silently
      # running once with an unbound `item` - see that method's own
      # comment for the shared when:-gate + strict-undefined-rescue shape
      # every one of the five loop-resolution call sites uses.
      begin
        loop_items = resolve_loop_items_or_raise(task, host, vars_context) do
          task.loop_items || resolve_first_found(task, host, vars_context) ||
            resolve_fileglob(task, host, vars_context, shared: shared_sub) ||
            resolve_with_file(task, host, vars_context, shared: shared_sub) ||
            resolve_loop_template(task, vars_context) ||
            resolve_loop_flattened(task, vars_context, host.name) ||
            resolve_loop_subelements(task, vars_context)
        end
      rescue ex : WhenEvaluationError
        # Same shape execute_task_once's own WhenEvaluationError rescue
        # uses for a when: failure - a real `failed: true` result flowing
        # through finish_single_task (register/notify/display/stats/halt,
        # ignore_errors: and all), recapping failed=1 (never reached the
        # loop, so never skipped=1 either) - matching real Ansible's own
        # degrade-to-one-clean-failed-task behavior.
        finish_single_task(task, host, when_error_result(ex))
        return
      end

      if loop_items
        begin
          execute_looped_task(task, host, vars_context, loop_items, exec_host)
        rescue ex : WhenEvaluationError
          # Strict loop-ITEM templating failure (deep_render_item) - same
          # degrade-to-one-clean-failed-task shape as the loop-SOURCE
          # resolution failure rescue above: real Ansible templates the
          # loop list with module-arg strictness before any iteration runs
          # (igor_nikiforov.etcd's `{{ etcd_config['data-dir'] }}` on a
          # dict missing that key), so this is one failed task, recapped
          # failed=1, with register/notify/halt/ignore_errors applied.
          finish_single_task(task, host, when_error_result(ex))
          return
        end
        return
      end

      if (until_condition = task.until_condition) && !resolve_task_check_mode(task, vars_context)
        execute_task_with_retries(task, host, vars_context, until_condition, exec_host)
        return
      end

      # Batching: if this task is part of a batch
      # group and batching applies to this host, its result comes from
      # (triggering, if not already done, then reading from) the group's
      # single shared SSH round trip instead of its own solo one -
      # everything downstream of getting a result is identical either
      # way.
      applies, batched_result = try_batched_result(task, host, vars_context, exec_host)
      if applies
        # A when:-skipped batch member returns {true, nil}: execute_batch_group
        # deferred its print and counter (defer_display/defer_stats) so the
        # group's skips aren't all emitted at once during batch-build; report
        # this member's skip here, in proper task order, exactly as the solo
        # path does via when_passes?.
        if batched_result.nil?
          print_batched_skip(task, host, vars_context)
          return
        end
        finish_single_task(task, host, batched_result)
        return
      end

      # Reached the plain single-execution path, so it will definitely be
      # used now: when_passes? and the param substitution inside
      # execute_task_once share this one instance.
      shared_sub ||= VarSubstitutor.new(vars: vars_context, host_name: host.name)

      result = execute_task_once(task, host, vars_context, exec_host: exec_host, shared: shared_sub)
      return unless result

      fact_host = (task.delegate_facts? && task.delegate_to) ? exec_host : host
      finish_single_task(task, host, result, fact_host)
    end

    # Resolve delegate_to: to the Host whose connection the module should
    # actually run against. Variables used to substitute a templated
    # delegate_to: value are still `host`'s own (real Ansible doesn't
    # delegate variables, only the connection).
    private def resolve_delegate_host(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : Host
      delegate_to = task.delegate_to
      return host unless delegate_to

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      target_name = substitutor.substitute(delegate_to)

      if (inventory = @inventory) && !(resolved = inventory.get_hosts(target_name)).empty?
        return resolved.first
      end

      fallback = Host.new(target_name, ENV["USER"]? || "root", 22)
      fallback.vars["ansible_connection"] = JSON::Any.new("local") if target_name == "localhost" || target_name == "127.0.0.1"
      fallback
    end

    # run_once: on every host after the first, skip execution outright but
    # still copy over whatever the first host's run registered, so a later
    # task on this host referencing it doesn't see an undefined variable.
    private def copy_run_once_register(task : Task, host : Host) : Nil
      register_name = task.register
      return if register_name.nil? || register_name.empty?

      if value = @registered_vars[@hosts.first.name][register_name]?
        @registered_vars[host.name][register_name] = value
        @hv_generation += 1
      end
    end

    # Render *task*'s `name:` for the "TASK [...]" banner, lazily - only
    # builds a vars_context (the same expensive facts-merge #execute_task
    # itself pays for separately) when the name actually needs it, so a
    # literal (the overwhelming majority) task name costs nothing extra.
    #
    # Every banner print site used to print `task.name` raw, which only
    # ever reflected whatever narrow, early, per-var-source pass had
    # already substituted into it (include_tasks:'s include_vars:,
    # include_role:'s vars:) - anything sourced from a role's own
    # `vars/main.yml` (round 26/27's `__common_binary_basename`, itself a
    # templated vars-file entry) or from `ansible_facts`/registered vars
    # stayed literally `{{ ... }}` in the banner even though the task's
    # own body rendered correctly, since the body gets a full vars_context
    # at actual execution time and the banner never did. Rendering here,
    # right before print, gives the banner the same full context the body
    # itself is about to use - it's cosmetic-only (a mistake here can't
    # affect what actually runs), so best-effort: on any substitution
    # error, fall back to the raw unrendered name rather than raising.
    private def evaluate_when(when_condition : String, vars_context : Hash(String, JSON::Any), host : Host, substitutor : VarSubstitutor? = nil) : Bool
      sub = substitutor || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      substituted_condition = sub.substitute(when_condition)

      begin
        # strict: true - a task `when:` must end in a real boolean on
        # ansible-core 2.19 (see ConditionalEvaluator#evaluate_truthiness);
        # ANSIBLE_ALLOW_BROKEN_CONDITIONALS relaxes it there and here.
        ConditionalEvaluator.evaluate(substituted_condition, vars_context, strict: true, raise_undefined: true)
      rescue ex
        raise WhenEvaluationError.new("Error while evaluating conditional: #{ex.message}")
      end
    end

    # Shared by all five loop-resolution call sites (execute_task,
    # execute_include_vars, execute_include_tasks, execute_include_role,
    # execute_handler_internal): resolves the loop source via the block,
    # and decides skip-vs-fail when that source turns out to be
    # genuinely undefined.
    #
    # Order matters and is live-verified (round174 differential matrix
    # against ansible-core 2.19.12, plus buluma.mount's own assert.yml):
    # real Ansible consults the task's OWN when: before treating an
    # undefined loop source as fatal.
    #
    #   when: false            + undefined loop -> skip  (scenario 7)
    #   when: item.x is defined + undefined loop -> skip  (`item` is
    #                             unbound, so `is defined` is false)
    #   no when:               + undefined loop -> FAIL  (scenario 1/1b)
    #
    # Note the middle case is why this must NOT be a pre-gate that
    # bails out whenever the condition mentions the loop variable: those
    # conditions are exactly the ones real Ansible still evaluates (with
    # `item` unbound) to decide the task is skippable. It equally must
    # not pre-empt a loop that resolves FINE - a normal defined loop with
    # `when: item.enabled` is evaluated per item downstream, untouched by
    # any of this, because this method only consults when: after the
    # resolution has actually raised.
    #
    # Returning nil on the skip path deliberately hands the task to the
    # ordinary non-looped route, where the EXISTING when_passes? call
    # skips it with correct "skipping:" output and skipped=1 accounting -
    # no separate skip bookkeeping needed here.
    #
    # A genuine failure surfaces as one WhenEvaluationError, flowing
    # through the exact same rescue/swallow_when_error/when_error_result/
    # finish_single_task plumbing 2f7b481 already built for when:
    # failures - no new exception type or rescue shape at any site, and
    # (critically, see 40671ba/0.9.539) no site can add a raising loop
    # resolver without also getting a working rescue, since every call is
    # wrapped by this method.
    # Real Ansible's with_items: (unlike loop:) implicitly applies
    # flatten(levels=1) across the rendered elements: `with_items: ["{{
    # list_a }}", "{{ list_b }}"]`, where list_a/list_b each render to
    # their own list, yields one iteration per INNER element (all of
    # list_a's items, then all of list_b's), not one iteration per outer
    # entry holding a whole list as `item`. Found via nicolai86.
    # prepare-release's own `with_items: ["{{ default_directories }}",
    # "{{ directories }}"]`, which previously bound the whole
    # default_directories array as a single `item` instead of iterating
    # its elements. Only called when task.loop_items_needs_flatten? (set
    # at parse time only for a literal with_items: array, never for
    # loop:, which has no such behavior).
    private def when_passes?(task : Task, vars_context : Hash(String, JSON::Any), host : Host, item_label : String? = nil, shared : VarSubstitutor? = nil, defer_stats : Bool = false, defer_display : Bool = false) : Bool
      # An unavailable-module task (see Task#unavailable_module) always
      # takes the skip path below, regardless of its own when: (or lack
      # of one) - it can never actually run, so it's treated the same as
      # a when:-false task rather than reached via real conditional
      # evaluation. It's still recorded into reachable_unavailable_modules
      # (for the final exit-code decision, see that getter's own comment)
      # if its own when: would have let it run - a raised
      # WhenEvaluationError (an undefined var the when: itself
      # references) is treated conservatively as "can't tell, don't
      # count" rather than crashing the run over this bookkeeping.
      #
      # EXCEPT: an unavailable module with a role-private `library/
      # <name>.py` source CAN run - the arbitrary-Python-module runner
      # (PythonModuleRunner) executes it on the target with the target's
      # own python3 - so such a task falls through to normal conditional
      # evaluation and dispatch instead of the skip (real Ansible runs
      # these as ordinary Python; the previous unconditional skip
      # diverged on every role leaning on its own library/, seen
      # repeatedly benchmarking linux-system-roles).
      if task.unavailable_module && python_module_source_for(task).nil?
        register_reachable_unavailable_module(task, vars_context, host, shared)
      else
        return true unless when_condition = task.when_condition

        return true if evaluate_when(when_condition, vars_context, host, shared)
      end

      # defer_stats: loop items and batch members pass this to only skip
      # the *counter* bump (aggregation happens once at the task level).
      # It does NOT suppress the print: loop items must still print their
      # per-item `skipping: [host] => (item=x)` line.
      unless defer_stats
        @results[host.name]["skipped"] += 1
      end

      # defer_display: additionally suppress the print, used by batch
      # members. execute_batch_group evaluates every member's when: while
      # building the group's single SSH round trip - printing each "skipping:"
      # there would emit all the group's skips at once, under the first
      # member's banner, instead of each under its own. The member's skip
      # print is deferred and emitted by execute_task when it consumes the
      # nil (skipped) result from the batch cache, in proper task order.
      unless defer_display
        suffix = item_label ? " => (item=#{item_label})" : ""
        puts "skipping: [#{host.connection_host}]#{suffix}".colorize(:cyan)
      end
      register_skip_result(task, host)
      false
    end

    # Builds the `failed: true` result shape a raised when: evaluation
    # produces, matching real Ansible's own "Task failed: Error while
    # evaluating conditional: ..." - for callers (execute_task_once,
    # execute_looped_task_batched) whose return value flows through the
    # normal result pipeline (finish_single_task/finish_looped_task),
    # which already knows how to apply stats/register/halt/ignore_errors:
    # correctly for a real failed result, so building one here instead of
    # hand-rolling that bookkeeping a second time keeps it consistent
    # with every other failure path.
    private def when_error_result(ex : WhenEvaluationError) : JSON::Any
      JSON.parse({"changed" => false, "failed" => true, "msg" => ex.message || "Error while evaluating conditional"}.to_json)
    end

    # For a `when_passes?` call site with no real per-item result
    # pipeline to flow a `WhenEvaluationError` through (a bare `meta:`
    # check, an `include_vars:` solo check, a mixed-task batch group
    # member) - replicates exactly what `when_passes?` itself used to do
    # inline before it started raising instead: stats/halt/register/
    # print, respecting `ignore_errors:` the same way `ResultDisplay.
    # update_stats` treats an ignored failure everywhere else (ok+=1 AND
    # ignored+=1, not failed+=1, host not halted - verified directly
    # against a real ansible-playbook run: `ignore_errors: true` on a
    # when:-raising task prints "...ignoring" and continues with `ok=2
    # ... ignored=1`, exit 0). Always returns `false`, the same "don't
    # run this task" signal every caller already treats a when:-skip as.
    private def swallow_when_error(task : Task, host : Host, ex : WhenEvaluationError, item_label : String? = nil, defer_stats : Bool = false, defer_display : Bool = false) : Bool
      msg = ex.message || "Error while evaluating conditional"
      unless defer_stats
        if task.ignore_errors?
          @results[host.name]["ok"] += 1
          @results[host.name]["ignored"] += 1
        else
          @results[host.name]["failed"] += 1
        end
      end
      @halted_hosts.add(host.name) unless task.ignore_errors?
      unless defer_display
        suffix = item_label ? " => (item=#{item_label})" : ""
        puts "fatal: [#{host.connection_host}]#{suffix}: FAILED! => #{msg}".colorize(:red)
        puts "...ignoring".colorize(:red) if task.ignore_errors?
      end
      register_name = task.register
      unless register_name.nil? || register_name.empty?
        register_result(host, register_name, JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => msg,
        }.to_json))
      end
      false
    end

    # A skipped task's own register: still gets set (to a `changed:
    # false, skipped: true` result, matching real Ansible) rather than
    # left holding whatever a previous task/loop iteration happened to
    # register under the same name. Without this, dev-sec os_hardening's
    # `register: mountpoint` / `when: mountpoint.changed` pair (each
    # include_tasks loop iteration reusing the same register name) leaks
    # a *prior* iteration's real "changed" result into a later iteration
    # whose own task was skipped, wrongly running the dependent task.
    private def print_batched_skip(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Nil
      puts "skipping: [#{host.connection_host}]".colorize(:cyan)
      @results[host.name]["skipped"] += 1
    end

    # Populates @task_group for *tasks* (a flat task list - a play's own
    # top-level tasks, or one block's/rescue's/always's nested list) the
    # first time it's seen, via TaskBatcher.plan. No-op if batching is
    # disabled or this exact list has already been planned.
    private def try_batched_result(task : Task, host : Host, vars_context : Hash(String, JSON::Any), exec_host : Host) : {Bool, JSON::Any?}
      return {false, nil} unless @batching_enabled
      return {false, nil} unless exec_host == host
      return {false, nil} if PluginManager.local_connection?(exec_host, vars_context)
      # A templated action:/local_action: resolves its real module only
      # inside execute_task_once; the batch script path has no such
      # resolution (and breaks_run? below only keeps the task out of
      # NEIGHBORS' groups - it would still batch as its own size-1
      # group), so it always takes the solo path.
      return {false, nil} if task.templated_action

      group = @task_group[task]?
      return {false, nil} unless group

      cache = (@batch_cache[host.name] ||= Hash(Task, {JSON::Any?, Hash(String, JSON::Any)}).new)

      # "Has this group already run on this host?" is tracked separately
      # from the cache's *contents*, precisely so consumed entries can be
      # evicted below. Keying the trigger check off `cache.has_key?
      # (group.first)` (as it used to) would make evicting group.first
      # cause the next member of the same group to re-run the entire
      # remote script - re-executing real side effects.
      group_key = {host.name, group.object_id}
      unless @batch_groups_run.includes?(group_key)
        @batch_groups_run << group_key
        # `task` is the group's trigger - its vars_context was already
        # built by the caller (execute_task), so hand it over instead of
        # having execute_batch_group build an identical one again.
        execute_batch_group(group, host, task, vars_context)
      end

      # Consumed exactly once per (task, host), so the entry is removed as
      # it is read. Each entry retains a full copy of that task's variable
      # context (~3.9 kB in a realistic run); nothing used to remove them,
      # so a play held N_tasks x N_hosts contexts alive until the whole
      # TaskExecutor was dropped - tens of MB for a large play under the
      # very --forks fan-out that makes big inventories attractive.
      #
      # Safe against the other reader: execute_task reads this same
      # entry's vars_context (index 1) *before* it calls into here, so by
      # the time the result (index 0) is read the context is no longer
      # needed. A member with no entry at all (the script halted before
      # reaching it) still yields nil, exactly as `cache[task]?` did.
      {true, cache.delete(task).try(&.[0])}
    end

    # Builds and runs the single SSH round trip for *group* against
    # *host*, populating @batch_cache[host.name] for every member that
    # either got a real result or was when:-skipped. A member that never
    # ran at all (the script halted at an earlier member, or an earlier
    # member's own action-plugin - e.g. template: - failed before any
    # remote call was even needed) gets NO cache entry; that's fine
    # because the failing member's own result (which DOES get a real
    # entry) sets @halted_hosts once the task-major loop processes it via
    # finish_single_task, and the loop's existing `next if
    # @halted_hosts.includes?(...)` guard then naturally skips ever
    # looking the later members up at all.
    #
    # Deliberately does none of the "did this task succeed/fail" side
    # effects itself (no register:/notify:/stats/display/halt) - those
    # all still happen exactly once, lazily, when the task-major loop
    # reaches each member and consumes it from the cache via
    # finish_single_task, in the same order it always has. This method's
    # only job is to fill the cache.
    private def execute_batch_group(
      group : Array(Task),
      host : Host,
      trigger_task : Task? = nil,
      trigger_vars_context : Hash(String, JSON::Any)? = nil,
    )
      cache = (@batch_cache[host.name] ||= Hash(Task, {JSON::Any?, Hash(String, JSON::Any)}).new)

      steps = [] of BatchScript::Step
      step_tasks = [] of Task
      step_vars = [] of Hash(String, JSON::Any)
      halted = false

      group.each do |task|
        break if halted

        vars_context = if task == trigger_task && (reused = trigger_vars_context)
                         reused
                       else
                         build_vars_context(task, host)
                       end

        # Same sharing as the solo path: when: and the step preparation
        # both read this member's identical vars_context.
        member_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

        # defer_stats + defer_display: a when:-skipped batch member has its
        # skipped counter AND its "skipping:" print both deferred - the
        # counter aggregates at the task level, and the print is emitted by
        # execute_task when it consumes this nil from the cache, so each
        # group member's skip prints under its own banner rather than all
        # at once here during batch-build.
        begin
          unless when_passes?(task, vars_context, host, shared: member_substitutor, defer_stats: true, defer_display: true)
            cache[task] = {nil, vars_context}
            next
          end
        rescue ex : WhenEvaluationError
          cache[task] = {when_error_result(ex), vars_context}
          next
        end

        case outcome = prepare_batch_step(task, host, vars_context, shared: member_substitutor)
        when JSON::Any
          cache[task] = {outcome, vars_context}
          failed = outcome["failed"]?.try(&.as_bool) || false
          halted = true if failed && !task.ignore_errors?
        when BatchScript::Step
          steps << outcome
          step_tasks << task
          step_vars << vars_context
        end
      end

      return if steps.empty?

      connection_host = PluginManager.get_connection_host(host, step_vars.first)
      step_results = run_batch_steps(host, connection_host, steps)

      steps.each_index do |idx|
        next unless interpreted = step_results[idx]?

        task = step_tasks[idx]
        vars_context = step_vars[idx]
        cache[task] = {apply_changed_failed_when(task, interpreted, vars_context, host), vars_context}
      end
    end

    # Shared "run this batch in one remote round trip and give back the
    # per-step results" middle, used by both execute_batch_group (mixed
    # tasks) and execute_looped_task's batched path (iterations of one
    # task) - the two callers differ only in how they produce *steps*.
    #
    # Results are keyed by index into *steps*, and an absent index means
    # that step NEVER RAN (an earlier one failed and stopped the batch).
    # Both transports below honour that identically, and both apply the
    # same fail-fast rule, so which one ran a group is not observable.
    #
    # Perf item 3: batching and the daemon
    # used to be mutually exclusive per task - a batched group always
    # went out as a fresh ssh + bash + base64 script, and the daemon
    # served only solo tasks, so every task took one optimization and
    # forfeited the other. The daemon transport is preferred now, and
    # the script remains the fallback for the cases it cannot serve.
    private def run_batch_steps(host : Host, connection_host : String, steps : Array(BatchScript::Step)) : Hash(Int32, JSON::Any)
      if result = try_daemon_batch(host, connection_host, steps)
        return result
      end

      interpreted = interpret_batch_script(host, connection_host, steps)

      # Perf item 6a's safety net, on the
      # BATCH path. Item 6a lets a run skip the "which plugin binaries
      # are present on this host" round trip when a previous run already
      # verified them. If that belief is wrong - /var/tmp swept, host
      # rebuilt behind the same address - the binary is missing and the
      # group fails.
      #
           # Caught by deliberately deleting the remote staging dir behind the
      # cache's back on a live host: without this the first run
      # afterwards lost a task (ok=4 failed=1) where the pre-item-6a
      # engine completed cleanly, because that engine always did the
      # listing round trip. That is a regression, not a pre-existing
      # rough edge, which is why the recovery has to cover this path and
      # not just PluginManager#execute_remote_plugin's one-shot path.
      #
      # Re-running the whole group is safe here specifically because a
      # missing binary means NOTHING in it ran: every step dispatches
      # the same binary, and the script fail-fasts at the first one.
      ssh_user = host.user || "root"
      if interpreted.any? { |_, step| PluginManager.missing_remote_binary_on_host?(step, "#{PluginManager.remote_plugin_dir(ssh_user)}/#{steps.first.module_name}", ssh_user) }
        PluginManager.recover_missing_plugins!(host, steps.map(&.module_name).uniq!, host.vars)
        return interpret_batch_script(host, connection_host, steps)
      end

      interpreted
    end

    private def interpret_batch_script(host : Host, connection_host : String, steps : Array(BatchScript::Step)) : Hash(Int32, JSON::Any)
      script_results = run_batch_script(host, connection_host, steps)
      interpreted = Hash(Int32, JSON::Any).new
      script_results.each do |idx, step_result|
        interpreted[idx] = PluginManager.interpret_remote_result(step_result.exit_code, step_result.stdout, step_result.stderr)
      end
      interpreted
    end

    # Returns nil when this group cannot (or should not) go over a
    # daemon, so the caller falls back to the script transport.
    #
    # The eligibility rule is one line of real substance: a daemon is a
    # single resident process running as ONE user, so every step in the
    # request has to agree on become_user. A group mixing `become: true`
    # and unprivileged tasks is left to the script, which resolves
    # privilege per step via its own `sudo -n -u ... --` prefix. That is
    # deliberately not "split the group into runs and send several
    # requests": each request is a round trip, and a group that needs
    # three of them is no longer obviously cheaper than the one script
    # the fallback already sends.
    #
    # On ANY daemon failure this returns nil and the whole group is
    # re-sent as a script. That carries the same re-execution window the
    # solo daemon path has always carried (see PluginManager#
    # execute_remote_plugin's own rescue) - a request whose response was
    # lost may have run - only widened from one task to one group.
    # Accepted for the same reason: the alternative is leaving those
    # members with no cache entry at all, which
    # execute_batch_group's contract reads as "skipped", silently NOT
    # running tasks the playbook asked for. A wrongly-repeated
    # idempotent module is a far better failure than a silently dropped
    # one.
    private def try_daemon_batch(host : Host, connection_host : String, steps : Array(BatchScript::Step)) : Hash(Int32, JSON::Any)?
      return nil unless PluginManager.daemon_enabled?
      return nil if steps.empty?

      become_user = steps.first.become_user
      return nil unless steps.all? { |step| step.become_user == become_user }
      return nil if steps.any?(&.module_name.empty?)

      ssh_user = host.user || "root"
      return nil if SSHManager.daemon_unavailable?(connection_host, ssh_user, host.port, become_user)

      payload = steps.map do |step|
        {
          module_name:   step.module_name,
          config:        JSON.parse(step.config_json),
          ignore_errors: step.ignore_errors?,
        }
      end

      begin
        SSHManager.daemon_send_batch(
          connection_host,
          ssh_user,
          host.port,
          "#{PluginManager.remote_plugin_dir(ssh_user)}/#{steps.first.module_name}",
          payload,
          identity_file: host.vars["ansible_ssh_private_key_file"]?.try(&.as_s?),
          become_user: become_user
        )
      rescue
        nil
      end
    end

    private def run_batch_script(host : Host, connection_host : String, steps : Array(BatchScript::Step)) : Hash(Int32, BatchScript::StepResult)
      batch_id = Random::Secure.hex(8)
      script = BatchScript.build(batch_id, steps)
      raw = SSHManager.exec_script(connection_host, host.user || "root", script, host.port, identity_file: host.vars["ansible_ssh_private_key_file"]?.try(&.as_s?))
      BatchScript.parse(raw[:stdout])
    end

    # Prepares one batch-group member up to (but not including) the
    # actual remote call - when: has already been checked by the caller.
    # Mirrors execute_task_once's own param-substitution/action-plugin/
    # config-building steps exactly, so a batched task's config is
    # byte-for-byte what a solo execution would have sent.
    #
    # Returns a JSON::Any if the task already has a final result without
    # ever needing a remote call (only possible today via an action
    # plugin - e.g. template: - failing to render, or an invalid
    # become_user:), or a BatchScript::Step ready to send otherwise.
    # Resolves a task's real become: value, re-rendering task.become_expr
    # against live vars if the YAML source was a templated expression
    # (`become: "{{ vault_privileged_install }}"`) rather than a literal
    # boolean. Parse time has no host/role vars context to render this
    # against, so the parser stashes the raw expression text and this is
    # where it actually gets evaluated - falls back to task.become (the
    # parser's best-effort literal guess) if there's no expr, or if
    # rendering it produces something ConditionalEvaluator can't use.
    # A task's effective check mode: its own `check_mode:` when it has
    # one, otherwise the run-wide `--check` flag. Real Ansible honours
    # BOTH directions (verified against ansible-core 2.19.4):
    # `check_mode: true` simulates a task during an ordinary run, and
    # `check_mode: false` lets a task really execute during a `--check`
    # run - the usual reason being a read-only `command:` whose output
    # the rest of the play needs in order to be simulated at all.
    #
    # Note what this deliberately does NOT touch: the
    # `ansible_check_mode` magic var stays bound to the RUN's mode, not
    # the task's. Live-verified - a `check_mode: true` task inside an
    # ordinary run still sees `ansible_check_mode == false`.
    private def prepare_batch_step(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil) : JSON::Any | BatchScript::Step
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)

      begin
        substituted_params = substitute_task_params(task.params, substitutor, native_containers: task.module_name.ends_with?("set_fact"), module_name: task.module_name)
      rescue ex
        # Same "finalization of task args failed" handling as
        # execute_task_once's own identical rescue (see there) - this
        # batched-path call site had no equivalent before, so a strict:
        # UndefinedVariableError (or a lookup('url', ...) HTTP failure,
        # the pre-existing case this class of rescue was built for) would
        # have crashed the whole run instead of failing just this task.
        failed = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => ex.message || "Failed to resolve task arguments",
        }.to_json)
        return apply_changed_failed_when(task, failed, vars_context, host)
      end

      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, host, vars_context)
      substituted_params = stage_unarchive_remote_src(task, substituted_params, host, vars_context)
      substituted_params = stage_script_src(task, substituted_params, host, vars_context)
      substituted_params = stage_assemble_dir(task, substituted_params, host, vars_context)
      substituted_become_user = task.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(task.module_name, substituted_params, vars_context, host)

        unless action_result.success?
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end

        # debug:/assert:/fail:/set_fact:/pause: - the action plugin
        # already computed the whole task result on the controller (see
        # ActionResult#final_result's own comment). No module upload/
        # dispatch of any kind, batched or not.
        if final = action_result.final_result
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        substituted_params = action_result.modified_params || substituted_params
      end

      become = resolve_task_become(task, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end
      end

      # Same override execute_remote_plugin applies to the wire payload
      # only (never to vars_context itself, which stays the controller's
      # own view for when:/changed_when:/failed_when: evaluation) - once
      # a plugin is actually running on the remote, its own internal
      # local-vs-remote logic needs to see itself as local.
      remote_vars_context = vars_context.dup
      remote_vars_context["ansible_connection"] = JSON::Any.new("local")

      config_json = build_plugin_config(task, host, substituted_params, remote_vars_context, substituted_become_user)

      # The batch script runs the plugin binary directly, so it must be on
      # the target before the script is built - pre-upload cannot see
      # modules that only appear inside a runtime include_tasks:.
      PluginManager.ensure_uploaded(host, task.module_name, vars_context)
      plugin_target = PluginManager.remote_plugin_target(task.module_name, become, become_user, host.user || "root")

      # The daemon transport (item 3) dispatches by module NAME inside an
      # already-running process, and takes its privilege from which
      # daemon the request is sent to - hence both of these alongside the
      # script transport's own `sudo`-prefixed target string. `nil`
      # become_user means "no become", which is a DIFFERENT daemon from
      # `"root"`, so the distinction is carried through rather than
      # normalized away.
      # Same "is this escalation a no-op?" test the script transport's own
      # target string already went through (PluginManager.become_needed?):
      # a `become: true` to the user we already are needs no daemon of its
      # own, and asking for one would spawn it under a `sudo` that real
      # Ansible never runs - and that a minimal host may not even have.
      BatchScript::Step.new(plugin_target, config_json, task.ignore_errors?,
        PluginManager.simple_plugin_name(task.module_name),
        PluginManager.become_needed?(become, become_user, host.user || "root") ? become_user : nil)
    end

    # Run one attempt of a task (when: check + param substitution + action
    # plugin + module execution). Returns nil if the when: condition skipped
    # it (the skipped counter is already updated in that case).
    # Runtime resolution of a templated action:/local_action: module name
    # (see Task#templated_action): substitute the whole free-form string,
    # take the first token as the module name (FQCN-resolved the same as
    # parse time), re-parse the rest as that module's params. Returns a
    # shallow copy - Task is shared across hosts and loop iterations, so
    # the resolved name/params must never be written back onto it. A
    # resolution failure raises (caught by the caller's "finalization of
    # task args failed" rescue) as one clean failed task - real Ansible's
    # own "couldn't resolve module/action 'x'" verdict for a templated
    # name that renders to something unknown.
    private def resolve_templated_action(task : Task, substitutor : VarSubstitutor) : Task
      raw = task.templated_action || return task

      rendered = substitutor.substitute(raw).strip
      tokens = rendered.split(/\s+/, 2)
      raw_name = tokens[0]
      resolved = PlaybookParser.resolve_module_name(raw_name)
      raise "couldn't resolve module/action '#{raw_name}'" unless resolved

      rest = tokens[1]?
      parsed = rest && !rest.strip.empty? ? PlaybookParser.parse_free_form_params(rest, resolved) : Hash(String, String).new
      # A sibling args: dict was already merged into task.params at parse
      # time - same precedence as the non-templated flow, args: win over
      # free-form k=v keys.
      merged = task.params.dup
      parsed.each { |key, value| merged[key] = value unless merged.has_key?(key) }

      resolved_task = task.dup
      resolved_task.module_name = resolved
      resolved_task.params = merged
      resolved_task
    end

    private def execute_task_once(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      item_label : String? = nil,
      exec_host : Host = host,
      shared : VarSubstitutor? = nil,
      defer_loop_stats : Bool = false,
    ) : JSON::Any?
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)

      begin
        return nil unless when_passes?(task, vars_context, host, item_label, shared: substitutor, defer_stats: defer_loop_stats)
      rescue ex : WhenEvaluationError
        # Returning a real `failed: true` result here (not swallowing
        # and returning `false`/nil) lets it flow through the exact same
        # pipeline a normal task failure does: the solo caller passes it
        # to `finish_single_task` (register/notify/display/stats/halt,
        # ignore_errors: and all), and - critically - a LOOPED caller
        # collects it into `finish_looped_task`'s per-item results array,
        # so a looped when: failure correctly aggregates to `failed=1`
        # in the recap (matching real Ansible's "One or more items
        # failed"), not `skipped=1` the way silently returning nil here
        # used to.
        return when_error_result(ex)
      end

      begin
        task = resolve_templated_action(task, substitutor)
        substituted_params = substitute_task_params(task.params, substitutor, native_containers: task.module_name.ends_with?("set_fact"), module_name: task.module_name)
      rescue ex
        # A raised exception during param substitution (e.g. lookup('url',
        # ...) hitting a real HTTP error - see ExpressionEvaluator#
        # fetch_url_lines's own comment) means real Ansible's own
        # "finalization of task args failed" hard stop: it fails the
        # ENCLOSING TASK cleanly (one recap entry, playbook continues to
        # whatever's next per normal when:/rescue: semantics), not the
        # whole run. Before this rescue existed, nothing in the call
        # chain up through krikri-playbook.cr's own top-level `run` caught
        # such an exception at all, so it crashed the entire process
        # with an unhandled-exception stack trace instead - found
        # benchmarking buluma.victoriametrics's own `set_fact: _checksums:
        # "{{ lookup('url', ...) }}"` against a 404'd release checksums
        # file (a broken-upstream default, but real Ansible still
        # degrades to one clean failed task, not a crash).
        result = JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => ex.message || "Failed to resolve task arguments",
        }.to_json)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.reboot"
        result = execute_reboot(substituted_params, exec_host, vars_context, resolve_task_check_mode(task, vars_context))
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.group_by"
        result = execute_group_by(substituted_params, host)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      if task.module_name == "ansible.builtin.set_stats"
        result = execute_set_stats(substituted_params, host, vars_context)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      substituted_params = resolve_role_relative_src(task, substituted_params)
      substituted_params = inline_copy_source_content(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_unarchive_remote_src(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_script_src(task, substituted_params, exec_host, vars_context)
      substituted_params = stage_assemble_dir(task, substituted_params, exec_host, vars_context)
      # become_user: goes through the same {{ }} substitution as any
      # params: value (e.g. become_user: "{{ service_user }}", a common
      # real-playbook pattern) - task.become_user itself is never mutated
      # here, since Task is shared/reused across hosts and loop iterations.
      substituted_become_user = task.become_user.try { |raw_user| substitutor.substitute(raw_user) }

      if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(
          task.module_name,
          substituted_params,
          vars_context,
          exec_host
        )

        unless action_result.success?
          result = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
          return apply_changed_failed_when(task, result, vars_context, host)
        end

        if final = action_result.final_result
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      # Same override execute_remote_plugin used to apply to the wire
      # payload only (never to vars_context itself, which stays the
      # controller's own view for when:/changed_when:/failed_when:
      # evaluation) - once a plugin is actually running on the remote,
      # its own internal local-vs-remote logic needs to see itself as
      # local. Deciding it *before* serializing is what lets the config
      # be built exactly once here, the way prepare_batch_step already
      # builds it once for the batch path; this used to serialize, parse,
      # then dup and re-serialize the entire variable context.
      wire_vars = vars_context
      if PluginManager.remote_execution?(task.module_name, exec_host, vars_context)
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      config = build_plugin_config(task, exec_host, substituted_params, wire_vars, substituted_become_user)

      if task.async_seconds && !resolve_task_check_mode(task, wire_vars)
        # async: writes this config verbatim to a job file; the detached
        # __async_run process resolves become:/become_user: back out of
        # it via the JSON::Any entry point, exactly as before. Remote
        # hosts take the SSH fire-and-forget path inside execute_async
        # (needs the substitutor/become_user context the local path
        # re-derives itself).
        return apply_changed_failed_when(task, execute_async(task, exec_host, config, vars_context, substitutor, substituted_become_user), vars_context, host)
      end

      # The same become resolution and validation resolve_become used to
      # perform from inside PluginManager, hoisted to the call site so
      # the config String can be handed straight through without being
      # parsed again. Identical defaults (become_user "root" when become:
      # is set but become_user: isn't) and identical error message -
      # and identical to what prepare_batch_step does for the batch path.
      become = resolve_task_become(task, substitutor)
      become_user = nil

      if become
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate

        unless PluginManager.valid_become_user?(become_user)
          failed = JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
          return apply_changed_failed_when(task, failed, vars_context, host)
        end
      end

      # The arbitrary-Python-module runner: an unavailable module with a
      # role-private `library/<name>.py` source dispatches to the
      # py_module plugin with the source embedded (base64), running it
      # on the target with the target's own python3. Reached only after
      # when_passes? let it through (see its own comment), so a python
      # module behind a false when: still skips normally.
      if task.unavailable_module && (py_source = python_module_source_for(task))
        result = execute_python_module(task, py_source, substituted_params, exec_host, wire_vars, substituted_become_user)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      result = PluginManager.execute_plugin(
        task.module_name,
        config,
        exec_host,
        vars_context,
        become,
        become_user
      )

      apply_changed_failed_when(task, result, vars_context, host)
    end

    # Dispatches an unavailable-module task that has a role-private
    # `library/<name>.py` source through the py_module plugin. The
    # source travels embedded in the plugin config (base64) so the
    # normal upload-and-execute transport works unchanged for remote
    # hosts; the module's argument dict mirrors real Ansible's typed
    # JSON args for new-style modules (the params the parser already
    # JSON-encoded come back as real arrays/dicts for the module).
    private def execute_python_module(task : Task, source_path : String, substituted_params : Hash(String, String), exec_host : Host, wire_vars : Hash(String, JSON::Any), substituted_become_user : String?) : JSON::Any
      module_name = PythonModuleRunner.short_name(task.unavailable_module || task.module_name)
      new_style = PythonModuleRunner.new_style?(File.read(source_path))
      check_mode = resolve_task_check_mode(task, wire_vars)

      py_params = substituted_params.dup
      py_params["module_name"] = module_name
      py_params["module_source"] = Base64.strict_encode(File.read(source_path))
      py_params["new_style"] = new_style.to_s
      py_params["check_mode"] = check_mode.to_s
      if new_style
        py_params["module_args"] = PythonModuleRunner.build_module_args(substituted_params, check_mode)
      else
        py_params["kv_argv"] = PythonModuleRunner.build_kv_argv(substituted_params).to_json
      end

      config = build_plugin_config(task, exec_host, py_params, wire_vars, substituted_become_user)
      PluginManager.execute_plugin(
        "ansible.builtin.py_module",
        config,
        exec_host,
        wire_vars,
        task.become?,
        substituted_become_user
      )
    end

    private def python_module_source_for(task : Task) : String?
      unavailable = task.unavailable_module || return nil
      PythonModuleRunner.find_source(
        PythonModuleRunner.short_name(unavailable),
        task.role_files_dir,
        @playbook_dir
      )
    end

    # async:/poll: - runs the module as a detached background OS process
    # (spawned via a hidden `__async_run` re-invocation of this same
    # binary, not a Fiber, so the job survives even if the poll loop or
    # the whole playbook run finishes first - closer to how real Ansible's
    # background job outlives the control connection). Local connections
    # use that path; REMOTE connections (round 189: mrlesmithjr.
    # change-hostname's own `shutdown -r now` + `async: 1`/`poll: 0`
    # reboot idiom) previously failed outright ("async: is only supported
    # for local connections"), so the host never rebooted while real
    # Ansible's fire-and-forget ran it. Remote async now mirrors real
    # Ansible's ~/.ansible_async model: the plugin binary is uploaded,
    # then nohup-launched detached on the target with its stdout (the
    # module's own JSON result) collected into ~/.ansible_async/<jid>
    # via an atomic tmp+mv, and poll:ed by cat-ing that file over SSH.
    private def apply_changed_failed_when(task : Task, result : JSON::Any, vars_context : Hash(String, JSON::Any), host : Host) : JSON::Any
      changed_when = task.changed_when
      failed_when = task.failed_when
      return result unless changed_when || failed_when

      eval_context = vars_context
      if (register_name = task.register) && !register_name.empty?
        eval_context = vars_context.dup
        eval_context[register_name] = with_command_lines_augmented(result)
      end

      # set_fact:'s own result carries the facts it just set under
      # "ansible_facts" (see SetFactActionPlugin), applied into the real
      # vars_context by the caller only AFTER this returns - but real
      # Ansible evaluates changed_when:/failed_when: against the task's
      # OWN result, which for set_fact already has those facts merged in.
      # Found via smlloyd.authselect (RHEL-family round 60487): `set_fact:
      # {authselect_current_profile: ...}` with a `changed_when:` that
      # references `authselect_current_profile` right back - real Ansible
      # resolves it fine, this engine raised "'authselect_current_profile'
      # is undefined" without this merge.
      if (facts = result.as_h?.try(&.[]?("ansible_facts"))) && (facts_hash = facts.as_h?)
        eval_context = eval_context.dup if eval_context.same?(vars_context)
        facts_hash.each { |key, value| eval_context[key] = value }
      end

      hash = result.as_h.dup

      # changed_when/failed_when share one substitutor: VarSubstitutor is
      # stateless with respect to a given vars hash (its only mutator,
      # set_variable, is never called from here), so building it twice
      # for the identical eval_context was pure waste.
      if changed_when || failed_when
        substitutor = VarSubstitutor.new(vars: eval_context, host_name: host.name)

        begin
          # raise_undefined: true - real ansible-core 2.19 raises while
          # EVALUATING a changed_when:/failed_when: that reaches an
          # undefined reference ("object of type 'dict' has no attribute
          # 'diff'" for cloudalchemy.pushgateway's own `changed_when`
          # against a result dict carrying no `diff` key) and fails the
          # task. This path used to be deliberately lenient - the miss
          # read as falsy and the task rc=0'd with "no change", which is
          # the same silent-corruption shape as an unrendered undefined
          # in a template: no error, wrong verdict, and everything
          # downstream trusting it. `when:` (Executor#when_passes?) and
          # `assert:` already own the identical flag; changed_when:/
          # failed_when: were the last lenient conditional entry point.
          # Same narrow scope as there: only a BARE or DOTTED reference
          # reaching evaluate_value's own "not found" exit raises - a
          # `| default(...)`-guarded chain stays lenient, as it must.
          if changed_when
            hash["changed"] = JSON::Any.new(ConditionalEvaluator.evaluate(substitutor.substitute(changed_when), eval_context, strict: true, raise_undefined: true))
          end

          if failed_when
            hash["failed"] = JSON::Any.new(ConditionalEvaluator.evaluate(substitutor.substitute(failed_when), eval_context, strict: true, raise_undefined: true))
          end
        rescue e : ConditionalEvaluator::ConditionalBooleanError | ConditionalEvaluator::UndefinedVariableError
          # Matches real Ansible: a changed_when:/failed_when: whose value
          # resolves to None (not a real boolean), or whose evaluation hits
          # an undefined variable / missing dict attribute, fails the task
          # outright rather than being silently truthy-converted to false.
          hash["failed"] = JSON::Any.new(true)
          hash["msg"] = JSON::Any.new(e.message || "")
        end
      end

      JSON::Any.new(hash)
    end

    # Register / notify / display / update stats for a (non-looped) task result.
    # fact_host is where a set_fact:/fact-gathering module's ansible_facts
    # attach - normally `host` itself, but the delegate_to:/delegate_facts:
    # combination redirects it to the delegate target instead (real
    # Ansible's own documented meaning); register:/display/stats always
    # stay attributed to `host` regardless.
    # Whether *task* on *host* should drop into the debugger, and the
    # loop that does. Returns the (possibly re-run) result.
    private def halt_if_failed(task : Task, host : Host, failed : Bool) : Nil
      @halted_hosts.add(host.name) if failed && !task.ignore_errors?
    end

    # Execute a task once per loop item, aggregating the per-item results
    # into a single registered variable (`{"changed": .., "results": [...]}`),
    # matching Ansible's shape for looped, registered tasks.
    private def inherit_when_condition(condition : String, tasks : Array(Task)?) : Nil
      return unless tasks

      tasks.each do |nested_task|
        existing = nested_task.when_condition

        if existing.nil? || existing.empty?
          nested_task.when_condition = condition
        elsif existing != condition && !existing.starts_with?("(#{condition}) and ")
          nested_task.when_condition = "(#{condition}) and (#{existing})"
        end

        # A nested block: is transparent - push through to its own
        # children, same as print_skipped_tasks does for the skip path.
        if nested_task.block?
          inherit_when_condition(condition, nested_task.block_tasks)
          inherit_when_condition(condition, nested_task.rescue_tasks)
          inherit_when_condition(condition, nested_task.always_tasks)
        end
      end
    end

    # Expands a block:-wrapped handlers/main.yml entry into its own
    # block_tasks, so a task's `notify:` naming the INNER task's name
    # (not the outer block's) resolves correctly - real Ansible flattens
    # block-nested handlers the same way. Found via robertdebock.rsyslog,
    # whose handlers/main.yml wraps its real handler purely to add
    # rescue-time diagnostics:
    #
    #   - name: Restart rsyslog block
    #     block:
    #       - name: Restart rsyslog
    #         ansible.builtin.service: {name: "{{ rsyslog_service }}", state: restarted}
    #     rescue:
    #       - name: Get rsyslog journal logs after service restart failure
    #         ...
    #
    # `notify: Restart rsyslog` (the inner task) used to abort the whole
    # run with HandlerNotFoundError - handler_answers_to?/HandlerRunner
    # only ever compared against the flat top-level handler.name, never
    # recursing into a block-type handler's own block_tasks.
    #
    # Verified live against real ansible-core 2.19.4 and 2.21.3 (both
    # agree) before writing this, since the obvious guess (teach
    # HandlerRunner to run a rescue-wrapped sub-block) turns out to be
    # WRONG:
    #   - Only block: members are flattened into notify-able handlers.
    #     rescue:/always: members are NOT flattened and are NOT
    #     individually notify-able either - completely inert for handler
    #     purposes. Confirmed live: notifying a rescue: task's own name
    #     directly still raises "handler not found".
    #   - The enclosing block's OWN name is never a valid notify target
    #     ("The requested handler 'Restart rsyslog block' was not
    #     found...").
    #   - Notifying a flattened member runs ONLY that one task - sibling
    #     block: tasks do not run alongside it, and rescue: does NOT fire
    #     even when the notified task itself fails (confirmed live:
    #     `rescued=0` in the recap; the run just fails fatally). So this
    #     method deliberately drops rescue_tasks/always_tasks entirely
    #     rather than flattening them too - they never become part of
    #     the flat handler list at all, matching that real "not found"/
    #     never-runs behavior exactly.
    #   - A block-level when: DOES apply to each flattened child
    #     (confirmed live: `when: false` on the block skips the notified
    #     inner handler with a normal `skipping:` line) - handled here
    #     via the same #inherit_when_condition helper #execute_block
    #     already uses for its own (different) when:-inheritance corner
    #     case.
    #
    # become:/become_user: need no extra handling - playbook_parser.cr's
    # parse_block_task already resolves those onto every block_tasks/
    # rescue_tasks/always_tasks entry at PARSE time (ambient save/
    # restore around the three child-list parses). Block-level when:/
    # vars:/role context are the two runtime-only exceptions
    # (#execute_block applies them just-in-time via
    # #inherit_when_condition/#propagate_role_context right before
    # running block_tasks) - since this flatten bypasses #execute_block
    # entirely for a handler-block, both must be applied explicitly here
    # instead, before the block's own Task object (and its now-orphaned
    # rescue_tasks/always_tasks) is discarded for good.
    #
    # Nesting a block: inside a block: used as a handler is a genuine
    # ansible-core parse-time error ("Using a block as a handler is not
    # supported") - this recurses through such a case instead of
    # replicating that error, a deliberately more lenient (never a worse
    # divergence) simplification.
    private def run_task_list(tasks : Array(Task), host : Host) : Nil
      ensure_grouped(tasks)

      tasks.each do |nested_task|
        break if @halted_hosts.includes?(host.name)
        # end_role: skip the ended role's remaining tasks silently (no
        # banner - execute_task's own check would skip the body but the
        # banner below would still print).
        next if role_ended_for_host?(nested_task, host)

        # A nested block: is transparent - like real Ansible, a named
        # block gets no "TASK [...]" banner of its own, only its members
        # do (execute_task already dispatches straight to execute_block,
        # which prints its own children's banners via this same
        # run_task_list). include_tasks: is NOT transparent - real
        # Ansible (and execute_include_tasks below) still shows a banner
        # for the include statement itself, so it keeps the banner here.
        # Found benchmarking prometheus.prometheus.alertmanager round
        # 134: a block-with-a-name nested inside another block (`_common`'s
        # "Download binary {{ }}"/"Verify checksum of {{ }}") printed a
        # spurious empty banner before its real children ran - this path
        # lacked the same block? dispatch run_task_batch (the multi-host
        # counterpart) already had.
        if nested_task.block?
          execute_task(nested_task, host)
          next
        end

        # A static import_role: (Task#is_static_import) is likewise
        # transparent - no banner of its own, only the included role's
        # own tasks (see is_static_import's own comment).
        if nested_task.include_role? && nested_task.is_static_import?
          execute_task(nested_task, host)
          next
        end

        puts "TASK [#{task_role_prefix(nested_task)}#{render_task_name_for_display(nested_task, host)}]".colorize(:white).bold
        puts "*" * 70
        execute_task(nested_task, host)
        puts ""
      end
    end

    # Runs an include_tasks: task. Unlike import_tasks (spliced into the
    # task list at parse time), this is resolved now: the file path may be
    # templated, and when:/loop: apply to the include statement itself
    # (gating/repeating the whole included set) rather than to each
    # included task individually.
  end
end
