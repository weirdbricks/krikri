require "./executor"
require "../controller_python"
require "../plugin_helpers/ansible_splitlines"
require "../plugin_helpers/script_pty_capture"
require "../module_utils_deprecations"

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
    # buffered per host: Ansible interleaves these lines as they
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
      # A meta: task does no remote work, so a worker fiber buys nothing -
      # and it must not need one: a raising when: on a meta: aborts the
      # whole run (see meta_when_fatal), an exception only the main fiber
      # can deliver to krikri-playbook's own rescue. A worker's uncaught
      # exception is merely reported at exit, leaving the rest of the play
      # to run.
      return false if task.meta?
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
    # - Ansible does not start the next batch after an abort
    # (verified: `serial: 1` + any_errors_fatal with h2 failing runs h1's
    # batch fully, then stops; h3 never runs at all).
    getter? play_aborted : Bool = false

    private def abort_play?(hosts : Array(Host)) : Bool
      return true if @play_aborted
      return false if hosts.empty?

      failed = hosts.count { |host| @halted_hosts.includes?(host.name) }
      return false if failed == 0

      triggered =
        if @any_errors_fatal
          true
        elsif limit = @max_fail_percentage
          # Strictly greater, matching Ansible. Ansible measures
          # _tqm._failed_hosts here, which never books a failure that
          # left a rescue:/always: chain running (see
          # @chain_pending_failures) - so those hosts don't count.
          counted = hosts.count { |host| @halted_hosts.includes?(host.name) && !@chain_pending_failures.includes?(host.name) }
          (counted * 100.0 / hosts.size) > limit
        else
          false
        end

      return false unless triggered

      @play_aborted = true
      hosts.each { |host| @halted_hosts << host.name }
      true
    end

    # ansible warns a task's reserved-name vars/register from
    # VariableManager.get_vars - once the strategy reaches the task, not
    # during the load (issue #473). The parser parked the text on the
    # Task; print it here, just before the task's own banner, and clear
    # it so each Task object warns once no matter how many hosts iterate
    # it. Called only after the halt/abort breaks: a task the play never
    # reaches (an earlier failure ended it) stays silent, like real.
    private def flush_pending_reserved_warning(task : Task) : Nil
      return unless text = task.pending_reserved_warning
      task.pending_reserved_warning = nil
      STDERR.print text
    end

    # Emits Ansible's UNREACHABLE! line for *host* and books it as
    # either ignored (ignore_unreachable:) or unreachable, halting the
    # host in the latter case.
    private def run_task_batch(tasks : Array(Task), hosts : Array(Host)) : Nil
      ensure_grouped(tasks)

      tasks.each do |task|
        next unless step_allows?(task)

        # A host known to be unreachable produces an unreachable result
        # for every task, exactly as Ansible does when the
        # connection keeps failing - and `ignore_unreachable: true`
        # makes that one ignored rather than fatal, letting the host go
        # on to the next task.
        #
        # The booking happens HERE (so the abort/halt decisions below
        # see it) but the report itself prints after the task banner:
        # ansible prints the banner first and the per-host results under
        # it - a fatal printed before the banner (or before the PLAY
        # banner, when this used to print straight from the pre-upload
        # pass) is a krikri-visible divergence (live-verified vs
        # ansible-core 2.19.11).
        pending_unreachable = [] of Host
        hosts.each do |host|
          next unless @unreachable_hosts.includes?(host.name)
          next if @halted_hosts.includes?(host.name)

          report_unreachable(task, host, @unreachable_ssh_errors[host.name]?, print: false)
          pending_unreachable << host
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

        # Once every host in scope is halted/unreachable, Ansible ends
        # the play right there rather than continuing to print empty "TASK
        # [...]" banners for the remaining tasks - a host can't become
        # active again within this same task list (only rescue:/always:
        # temporarily un-halt, and those run via their own separate
        # run_task_batch call). Found via geerlingguy.raspberry-pi: a
        # single-host play kept printing banners for every task after its
        # one host failed and halted. The task whose booking made them
        # unreachable still prints its banner and those hosts' reports
        # (pending_unreachable non-empty) - ansible shows
        # "TASK [Gathering Facts]" + the fatal, not a bare fatal.
        break if halt_rejected.empty? && pending_unreachable.empty?

        flush_pending_reserved_warning(task)

        # Same treatment role_ended's filter gets: a host whose per-host
        # dependency dedup already credits this identity to an earlier
        # occurrence produces NOTHING for this task (issue #320) - not a
        # `skipping:` line, not a failing/included line, and not a banner
        # when it's the only kind of host left, matching real's silent
        # batch drop for a role that ran before.
        active_hosts = halt_rejected.reject do |host|
          role_ended_for_host?(task, host) || role_dep_dedup_skipped_for_host?(task, host)
        end
        # Every active host had this role ended for it - a fully consumed
        # task prints nothing at all (Ansible's silent iterator
        # consume), but later tasks outside the role still run - unless
        # this task also owes pending unreachable reports, which print
        # under the task's banner like any other per-host result.
        if active_hosts.empty?
          unless pending_unreachable.empty?
            unless @adhoc || (task.include_role? && task.is_static_import?)
              Krikri::OutputBanner.banner("TASK [#{task_role_prefix(task)}#{render_task_name_for_display(task, hosts.first)}]")
              print_task_path(task)
            end
            flush_pending_unreachable(pending_unreachable)
          end
          next
        end

        if task.block?
          flush_pending_unreachable(pending_unreachable)
          execute_block_multi(task, active_hosts)
          next
        end

        if task.include_tasks? && !task_has_loop?(task)
          flush_pending_unreachable(pending_unreachable)
          execute_include_tasks_multi(task, active_hosts)
          next
        end

        # The banner prints once per task, not per host - Ansible's
        # own convention - so a templated name is rendered against
        # whichever host will actually run first (matches this file's
        # existing `run_once`-style "first host" precedent elsewhere).
        # A static import_role: (Task#is_static_import) gets no banner of
        # its own, same as block: above - only the included role's own
        # tasks do (see is_static_import's own comment).
        unless @adhoc || (task.include_role? && task.is_static_import?)
          display_host = active_hosts.first? || hosts.first
          task_display_name = render_task_name_for_display(task, display_host)
          # Real loads a task's ACTION plugin lazily, right before the task's
          # own banner - before its `when:` is even evaluated, so a skipped
          # task warns too (live-verified vs ansible-core 2.21.6) - and a
          # controller-side action plugin importing from a deprecated
          # ansible.module_utils path warns there. synchronize's does on the
          # 2.1.x release line (see ModuleUtilsDeprecations, whose release
          # gate keeps the 2.2.x line silent); emitting it here puts the
          # lines between the play and this task's banners, once per run
          # (Display dedups the text), exactly where real prints them.
          ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts(
            task.module_name, CollectionIndex.module_provider_version(task.module_name)).each do |text|
            Krikri::ResultDisplay.emit_core_deprecation(text)
          end
          Krikri::OutputBanner.banner("TASK [#{task_role_prefix(task)}#{task_display_name}]")
          # The profile_tasks aggregate callback's per-task timestamp line
          # fires here too - banner or no banner (under the oneline stdout
          # callback the banner itself is suppressed but the timestamp
          # line still prints, live-verified), and handlers/facts get the
          # same treatment at their own banner sites.
          Krikri::ProfileTasks.record_task_start(task, task_display_name)
          print_task_path(task)
        end
        # The buffered unreachable reports go under the banner, before
        # the reachable hosts' results - a refused connection completes
        # long before a real task does, so ansible's result order puts
        # the fatal line first (live-verified vs 2.19.11).
        flush_pending_unreachable(pending_unreachable)

        if @forks > 1 && task_forkable?(task) && active_hosts.size > 1 && task.throttle != 1 && (task.debugger || @debugger).nil?
          run_task_for_hosts_in_parallel(task, active_hosts)
        else
          active_hosts.each { |host| execute_task(task, host) }
        end

        puts "" if @adhoc
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
    # include_tasks: caller leaves this false: there, Ansible fails
    # the single include task itself (verified live, round173), so the
    # swallow path below is already correct for it.
    # *skip_conditions*, when given, collects each skipped host's own failing
    # when: clause - the batched include_tasks caller needs it to register the
    # skip result per host (issue #888) after this method has moved on to
    # later hosts, by which time @last_false_condition no longer holds that
    # host's clause.
    private def partition_by_when(task : Task, hosts : Array(Host), inherit_on_error : Bool = false, skip_conditions : Hash(String, String)? = nil) : {Array(Host), Array(Host)}
      return {hosts, [] of Host} unless task.when_condition

      run_hosts = [] of Host
      skip_hosts = [] of Host
      hosts.each do |host|
        vars_context = nil
        begin
          vars_context = build_vars_context(task, host)
        rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
          # Same degrade-to-one-clean-failed-task shape as execute_task's
          # own build_vars_context rescue (0.9.885) and the include_
          # tasks/include_role/include_vars paths' own rescues: the task's
          # own `vars:` block used an unknown filter, Ansible fails
          # just that task with "No filter named 'X'." - a raise here only
          # affects THIS host (same as the WhenEvaluationError rescue
          # below); the failed host is excluded from both run_hosts and
          # skip_hosts. (inherit_on_error's push-down-to-children doesn't
          # apply: the error is deterministic, so every child would fail
          # the same way - swallow once per host instead.)
          swallow_when_error(task, host, WhenEvaluationError.new(ex.message || "Failed to render task vars"))
        end
        next if vars_context.nil?
        begin
          if evaluate_when_items(task, vars_context, host)
            if inherit_on_error
              # Ansible re-evaluates the block's when: on every child.
              inherit_block_when(task, task.block_tasks)
              inherit_block_when(task, task.rescue_tasks)
              inherit_block_when(task, task.always_tasks)
            end
            run_hosts << host
          else
            skip_hosts << host
            if conditions = skip_conditions
              conditions[host.name] = @last_false_condition || ""
            end
          end
        rescue ex : WhenEvaluationError
          # A raise here only affects THIS host - every other host in
          # *hosts* still gets partitioned normally.
          if inherit_on_error
            inherit_block_when(task, task.block_tasks)
            inherit_block_when(task, task.rescue_tasks)
            inherit_block_when(task, task.always_tasks)
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
      # throttle: caps concurrency for this task BELOW --forks -
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
      # ansible-playbook reports the fast host first when a slower
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
      # counter (Ansible's iterator peek/consume behavior). The
      # check sits here, the single funnel every task path (top-level
      # loop, blocks, nested include_role/include_tasks lists) goes
      # through, so the run loop's own active_hosts rejection above only
      # exists to keep the banner from printing for fully-consumed tasks.
      return if role_ended_for_host?(task, host)
      return if role_dep_dedup_skipped_for_host?(task, host)

      return execute_block(task, host) if task.block?
      return execute_include_tasks(task, host) if task.include_tasks?
      return execute_include_role(task, host) if task.include_role?
      if task.meta?
        # `when:` on a meta: task was previously never evaluated at all -
        # latent since meta: shipped (clear_facts/flush_handlers are
        # rarely when:-gated in practice), surfaced adding end_host/
        # end_play, whose whole point is frequently being conditional
        # per host. Verified against ansible-playbook: a when:-false
        # meta: task prints "skipping: [host]" but - like every other
        # meta: outcome - does NOT bump the recap's skipped= counter
        # (defer_stats: true), unlike an ordinary task's when: skip.
        #
        # EXCEPT the actions real refuses a when: for (see
        # meta_ignores_when?): those are never gated at all - the action
        # runs whatever the conditional says (a false or even a raising
        # one), which is why that conditional must not be evaluated here
        # either.
        if meta_ignores_when?(task)
          execute_meta(task, host)
          return
        end
        vars_context = build_vars_context(task, host)
        begin
          passes = when_passes?(task, vars_context, host, defer_stats: true)
        rescue ex : WhenEvaluationError
          # Real's strategy evaluates a meta: task's when: itself and lets
          # a raise escape the run entirely - see meta_when_fatal.
          raise meta_when_fatal(task, host, ex)
        end
        execute_meta(task, host) if passes
        return
      end
      return execute_include_vars(task, host) if task.include_vars?
      return execute_validate_argument_spec(task, host) if task.validate_argument_spec?

      # run_once: only ONE host in the play actually executes it; later
      # hosts get no output/stats at all, matching Ansible - but
      # still pick up whatever it registered, so later tasks on those
      # hosts can reference the same variable. Which host executes is
      # elected on first arrival (the first host to reach this point for
      # this task) rather than pinned to the literal first inventory
      # host - if that host is unreachable/halted the task used to never
      # run anywhere, while Ansible runs it on the first *active*
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
      vars_context = @batch_cache[host.name]?.try(&.[task]?).try(&.[1])
      unless vars_context
        begin
          # loop_lenient_vars: a looped task's vars: render with `item`
          # unbound here, but Ansible only ever evaluates a looped
          # task's vars: per actual iteration - a zero-iteration loop
          # (stackhpc.luks round 960004) never evaluates them at all, and
          # a non-empty loop re-renders them per item inside the loop
          # paths. See build_vars_context's loop_lenient_vars comment.
          vars_context = build_vars_context(task, host, loop_lenient_vars: task_has_loop?(task))
        rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
          # build_vars_context renders the task's own `vars:` block
          # (render_task_vars) - and while a vars: expression that
          # legitimately raises is dropped raise-to-absent there, an
          # unknown filter name is deliberately re-raised (see
          # render_task_vars's own rescue): Ansible hard-fails the
          # task with "No filter named 'X'." (nephelaiio.pip /
          # nephelaiio.gitlab's own nephelaiio.plugins.sorted_get).
          # Nothing between here and krikri-playbook's top-level run
          # caught it, so the whole process crashed with an unhandled
          # exception instead of this one clean failed task (recapped
          # failed=1), the same degrade-to-failed-task shape the loop-
          # source resolution failure rescue below uses.
          finish_single_task(task, host, when_error_result(WhenEvaluationError.new(ex.message || "Failed to render task vars"), task, host))
          return
        end
      end

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
      # Loop-SOURCE resolution runs against the alias-free snapshot (Ansible's own scoping - see #synthesize_legacy_ssh_aliases), while
      # delegate_to: and everything downstream of loop resolution keeps
      # the full task-arg context.
      loop_vars_context = loop_source_vars_context(task, host, vars_context)
      loop_shared_sub = nil.as(VarSubstitutor?)
      if task.delegate_to || task.loop_fileglob || task.loop_file
        shared_sub = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        if task.loop_fileglob || task.loop_file
          loop_shared_sub = VarSubstitutor.new(vars: loop_vars_context, host_name: host.name)
        end
      end

      # A looped task's delegate_to: may reference the loop variable
      # (geerlingguy.kubernetes' `delegate_to: "{{ item }}"`), which is not
      # bound yet here - so the strict check runs on the per-item
      # re-resolution inside execute_looped_task instead, and this
      # pre-loop resolution stays lenient for looped tasks exactly as
      # before.
      exec_host = if task.delegate_to && !task_has_loop_source?(task)
                    begin
                      resolve_delegate_host(task, host, vars_context, shared: shared_sub, strict: true)
                    rescue ex : WhenEvaluationError
                      # Ansible templates delegate_to: BEFORE when:, so a
                      # delegate template that fails (undefined variable, a
                      # dict missing a key) fails the task even when the
                      # when: is False - live-verified vs 2.19.11, issue
                      # #661 (wittdennis.kubernetes_node_uncordon's "Wait
                      # for cilium": when False by default, delegate group
                      # undefined, real prints the fatal [ERROR] block and
                      # aborts the play).
                      if ex.is_a?(EmptyDelegateError)
                        emit_empty_delegate_error_block(task)
                        # Only the fatal line's `host -> target` label is read from
                        # this host: ansible prints the raw delegate_to: text there.
                        label_host = Host.new(task.delegate_to.to_s, ENV["USER"]? || "root", 22)
                        finish_single_task(task, host, loop_error_result(ex, task), vars_context: vars_context, exec_host: label_host)
                        return
                      end
                      finish_delegate_template_failure(task, host, ex, vars_context)
                      return
                    end
                  else
                    resolve_delegate_host(task, host, vars_context, shared: shared_sub)
                  end

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
        loop_items = resolve_loop_items_or_raise(task, host, loop_vars_context) do
          task.loop_items || resolve_first_found(task, host, loop_vars_context) ||
            resolve_fileglob(task, host, loop_vars_context, shared: loop_shared_sub) ||
            resolve_with_file(task, host, loop_vars_context, shared: loop_shared_sub) ||
            resolve_loop_template(task, loop_vars_context) ||
            resolve_loop_nested(task, loop_vars_context, host.name) ||
            resolve_loop_together(task, loop_vars_context, host.name) ||
            resolve_loop_flattened(task, loop_vars_context, host.name) ||
            resolve_loop_subelements(task, loop_vars_context) ||
            resolve_loop_filetree(task, host, loop_vars_context, shared: loop_shared_sub) ||
            resolve_loop_lookup(task, loop_vars_context)
        end
      rescue ex : LoopTypeError | LoopLookupError
        # A loop source that IS defined but resolves to a non-list (or a
        # lookup term of the wrong type): real fails the task AT KEYWORD
        # FINALIZATION with its own [ERROR] block and a BARE registered
        # msg - no "Task failed: " prefix, no "Module failed." middle,
        # and no when: ever shields it (live-verified vs 2.19.11: a
        # defined-null `loop:` fails even behind `when: false`, round
        # 5410000). Emit the typed block here (result_display's own
        # generic chain is suppressed via the result's marker) and ride
        # the normal single-task failure pipeline (stats/halt/register).
        emit_loop_source_error_block(task, ex)
        # exec_host rides along so the fatal line keeps the delegated
        # label (a loop-source failure still prints [host -> delegate],
        # CallbackBase.host_label reads the task keyword); the literal
        # "undefined" a loop-variable delegate_to: leniently renders to
        # before any item exists is dropped - real never templated
        # delegate_to there either.
        finish_single_task(task, host, loop_source_error_result(ex, task), vars_context: vars_context, exec_host: exec_host.name == "undefined" ? nil : exec_host)
        return
      rescue ex : WhenEvaluationError
        # Real templates delegate_to: BEFORE any loop item exists, so when
        # the loop source itself cannot be evaluated the failure real
        # reports is the delegate_to: template's own (e.g. `'item' is
        # undefined`), not the loop-source error - issue #513,
        # githubixx.kubernetes_ca, live-verified vs 2.19. Re-resolve
        # strictly with `item` unbound; only a delegate template that
        # actually fails diverts to the delegate-failure shape, everything
        # else (delegate resolves fine, or an empty-delegate failure)
        # keeps the loop-error behaviour below.
        if task.delegate_to
          begin
            resolve_delegate_host(task, host, vars_context, shared: shared_sub, strict: true)
          rescue err : WhenEvaluationError
            unless err.is_a?(EmptyDelegateError)
              finish_delegate_template_failure(task, host, err, vars_context)
              return
            end
          end
        end
        # Same shape execute_task_once's own WhenEvaluationError rescue
        # uses for a when: failure - a real `failed: true` result flowing
        # through finish_single_task (register/notify/display/stats/halt,
        # ignore_errors: and all), recapping failed=1 (never reached the
        # loop, so never skipped=1 either) - matching Ansible's own
        # degrade-to-one-clean-failed-task behavior. Ansible 2.19.11 also
        # prefixes the loop-source error with "Task failed: " and prints
        # the fatal JSON with changed=false (live-verified: `loop: "{{
        # no_such_list }}"` on an undefined var → fatal {"changed": false,
        # "msg": "Task failed: 'no_such_list' is undefined"}).
        prefixed = ex.message.to_s.starts_with?("Task failed: ") ? ex.message.to_s : "Task failed: #{ex.message}"
        emit_loop_error_chain(task, prefixed, host)
        finish_single_task(task, host, loop_error_result(WhenEvaluationError.new(prefixed), task), vars_context: vars_context, exec_host: exec_host.name == "undefined" ? nil : exec_host)
        return
      end

      if loop_items
        begin
          execute_looped_task(task, host, vars_context, loop_items, exec_host)
        rescue ex : WhenEvaluationError
          # Strict loop-ITEM templating failure (deep_render_item) - same
          # degrade-to-one-clean-failed-task shape as the loop-SOURCE
          # resolution failure rescue above: Ansible templates the
          # loop list with module-arg strictness before any iteration runs
          # (igor_nikiforov.etcd's `{{ etcd_config['data-dir'] }}` on a
          # dict missing that key), so this is one failed task, recapped
          # failed=1, with register/notify/halt/ignore_errors applied.
          # Same "Task failed: " prefix + chain treatment as the loop-
          # source rescue above.
          prefixed = ex.message.to_s.starts_with?("Task failed: ") ? ex.message.to_s : "Task failed: #{ex.message}"
          emit_loop_error_chain(task, prefixed, host)
          finish_single_task(task, host, loop_error_result(WhenEvaluationError.new(prefixed), task), vars_context: vars_context, exec_host: exec_host.name == "undefined" ? nil : exec_host)
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
        finish_single_task(task, host, batched_result, vars_context: vars_context)
        return
      end

      # Reached the plain single-execution path, so it will definitely be
      # used now: when_passes? and the param substitution inside
      # execute_task_once share this one instance.
      shared_sub ||= VarSubstitutor.new(vars: vars_context, host_name: host.name)

      result = execute_task_once(task, host, vars_context, exec_host: exec_host, shared: shared_sub)
      return unless result

      fact_host = (task.delegate_facts? && task.delegate_to) ? exec_host : host
      finish_single_task(task, host, result, fact_host, vars_context: vars_context, exec_host: exec_host)
    end

    # The task-failure shape a failed delegate_to: template produces
    # (live-verified vs 2.19, issues #661 and #513): the [ERROR] chain
    # with the caused-by Origin on the delegate_to: value, and a fatal
    # line whose `host -> target` label carries the raw delegate_to:
    # text. Shared by the pre-loop strict resolution and the loop-source
    # failure rescue, which both can surface this same shape.
    private def finish_delegate_template_failure(task : Task, host : Host, ex : WhenEvaluationError, vars_context : Hash(String, JSON::Any)) : Nil
      prefixed = ex.message.to_s.starts_with?("Task failed: ") ? ex.message.to_s : "Task failed: #{ex.message}"
      emit_delegate_error_chain(task, prefixed)
      label_host = Host.new(task.delegate_to.to_s, ENV["USER"]? || "root", 22)
      finish_single_task(task, host, loop_error_result(WhenEvaluationError.new(prefixed), task), vars_context: vars_context, exec_host: label_host)
    end

    # Resolve delegate_to: to the Host whose connection the module should
    # actually run against. Variables used to substitute a templated
    # delegate_to: value are still `host`'s own (Ansible doesn't
    # delegate variables, only the connection).
    #
    # strict: templates the delegate_to: value with module-arg strictness -
    # a genuinely undefined bare reference raises WhenEvaluationError (the
    # same clean task-failure channel the loop-resolution sites use)
    # instead of the old behavior of rendering the undefined value as the
    # literal string "undefined" and returning a Host literally named
    # "undefined" (aheimsbakk.restic_backup's "Destination - create
    # destination user": the subsequent plugin upload then died as an
    # unhandled "ssh: Could not resolve hostname undefined" exception that
    # aborted the whole run, where Ansible fails just the task with
    # "'restic_backup_destination_server' is undefined"). Deliberately
    # narrow: only a bare/chain reference is strict (substitute's own
    # strict: boundary) - compound expressions with filters keep the
    # lenient rendering, same as everywhere else.
    private def resolve_delegate_host(task : Task, host : Host, vars_context : Hash(String, JSON::Any), shared : VarSubstitutor? = nil, strict : Bool = false) : Host
      delegate_to = task.delegate_to
      return host unless delegate_to

      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)
      target_name = begin
        substitutor.substitute(delegate_to, strict: strict)
      rescue ex : UndefinedVariableError
        if strict
          # The RAW inner error text - callers add the "Task failed: "
          # prefix themselves and point the chain's caused-by Origin at
          # the delegate_to: value (live-verified vs 2.19.11, issue #661);
          # the old "The task includes an option with an undefined
          # variable." wrap was the module-args wording, which real does
          # not use here.
          raise WhenEvaluationError.new(ex.message)
        end
        raise ex
      end

      # Ansible fails the task when delegate_to: templates to an empty
      # hostname, instead of handing an empty name to the connection
      # plugin. Only the strict (per-task / per-item) callers raise; the
      # lenient pre-loop resolution keeps returning the host as before.
      if strict && target_name.empty?
        raise EmptyDelegateError.new("Task failed: Empty hostname produced from delegate_to: \"#{delegate_to}\"")
      end

      if (inventory = @inventory) && !target_name.empty? && !(resolved = inventory.get_hosts(target_name)).empty?
        return resolved.first
      end

      fallback = Host.new(target_name, ENV["USER"]? || "root", 22)
      # Ansible's fallback for an unresolvable delegate name is a plain SSH
      # host (connection plugin defaults to smart->ssh, not to the origin
      # host's connection): a delegate not in inventory never inherits the
      # origin's ansible_connection=local, so `delegate_to:
      # some.invalid.name` from a local controller host really runs ssh
      # against the name and fails that task UNREACHABLE (issue #102) -
      # without the explicit "ssh" here, PluginManager.local_connection?'s
      # vars fallback re-inherited the origin's "local" and ran the task
      # on the controller.
      if target_name == "localhost" || target_name == "127.0.0.1"
        fallback.vars["ansible_connection"] = JSON::Any.new("local")
        # This fallback stands in for real's IMPLICIT localhost, which
        # carries ansible_python_interpreter = its own sys.executable
        # (`_create_implicit_localhost`): a task delegated to localhost
        # runs its module under the Python ansible itself runs under,
        # where libraries installed beside ansible live (boto3, issue
        # #1005). An inventory-defined localhost keeps its own vars.
        ControllerPython.apply_implicit_localhost_interpreter(fallback.vars)
      else
        fallback.vars["ansible_connection"] = JSON::Any.new("ssh")
      end
      fallback
    end

    # The vars a delegated task's actual dispatch (connection resolution,
    # upload/exec, wire config) must see: the delegated host's own
    # connection vars, not the origin host's context. build_vars_context
    # is built for the ORIGIN host - it injects ansible_host as the
    # origin's inventory name and merges the origin's inventory
    # connection vars - and ConnectionSettings.resolve tiers the passed
    # vars ABOVE the target host's own, so a delegated dispatch saw the
    # origin's ansible_host/ansible_port/ansible_user: delegating from
    # host A to inventory host B ssh'd back to A, and (issue #102) a
    # not-in-inventory delegate name inherited the origin's
    # ansible_connection=local outright and ran on the controller.
    # Ansible builds a delegated connection from the delegated host's
    # own vars, so the delegate's own values win here; ansible_host/
    # ansible_ssh_host are dropped outright when the delegate defines
    # none - the origin's injected value must never name the ssh target,
    # and ansible falls back to the delegate's own name. The same
    # fallback rule the not-in-inventory delegate applies: the
    # delegate's own connection setting, local for the localhost
    # spellings, ssh otherwise - a delegate never inherits the origin's
    # connection plugin. Keys the delegate does not define keep the
    # origin context's value (unchanged behavior; only ansible_host,
    # which build_vars_context fabricates for every origin host, and
    # ansible_connection are dropped, so a task-level connection var
    # override on the delegated task itself still applies where
    # ansible's own task-vars tier would put it).
    private def delegated_dispatch_vars(host : Host, exec_host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      dispatch = vars_context.dup
      dispatch.delete("ansible_host")
      dispatch.delete("ansible_ssh_host")
      exec_host.vars.each do |key, value|
        dispatch[key] = value if ConnectionSettings::CONNECTION_VAR_KEYS.includes?(key)
      end
      unless dispatch.has_key?("ansible_host") || dispatch.has_key?("ansible_ssh_host")
        dispatch["ansible_host"] = JSON::Any.new(exec_host.name)
      end
      dispatch["ansible_connection"] =
        exec_host.vars["ansible_connection"]? || JSON::Any.new("ssh")
      # Which Python runs the module is the DELEGATE's business in real
      # ansible - that is how `delegate_to: localhost` ends up under the
      # implicit localhost's own interpreter (issue #1005) - so the
      # delegate's interpreter keys replace the origin's. They are not
      # connection keys (CONNECTION_VAR_KEYS), hence this separate step.
      #
      # A delegate's values are HOST vars, though, and real ranks the
      # origin's play/block/task vars above them: a delegated task that
      # pins ansible_python_interpreter in its own `vars:`, in its block
      # or in the play runs under THAT interpreter (verified live against
      # ansible-core 2.21.6), while the origin host's own inventory value
      # never applies to the delegate at all. Both shapes reach this same
      # merged context, so the origin's raw inventory value is the tell:
      # anything else in the context outranks the delegate's host var.
      INTERPRETER_VAR_KEYS.each do |key|
        value = exec_host.vars[key]?
        next unless value
        existing = dispatch[key]?
        next if existing && existing != host.vars[key]?
        dispatch[key] = value
      end
      dispatch
    end

    # The vars that select the Python a module runs under (issue #1005):
    # ansible_python_interpreter when the host pins one, and the
    # interpreter discovery recorded in discovered_interpreter_python.
    INTERPRETER_VAR_KEYS = ["ansible_python_interpreter", "discovered_interpreter_python"]

    # The `-> target` label for display sites that have no already-
    # resolved exec_host at hand (loop-source failure lines,
    # include_vars:' own controller-side display paths, block-skip loop
    # failures). Ansible's default callback stamps `host -> delegate` on
    # every ok/changed/fatal line of a delegated task straight from the
    # task keyword (CallbackBase.host_label), so the label exists even
    # where the engine never built a connection - a loop-source failure
    # or a failed_when:-suppressed include_vars: still prints it.
    # Resolved leniently: nil when the delegate cannot be resolved at
    # all (the plain host line, as before), and nil for the literal
    # "undefined" a looped task's delegate_to: renders to before the
    # loop variable is ever bound - a loop-source failure happens before
    # any item exists, so real never templated delegate_to there either.
    private def delegate_display_target(task : Task, host : Host, vars_context : Hash(String, JSON::Any)? = nil) : String?
      return nil unless task.delegate_to
      context = vars_context || (build_vars_context(task, host) rescue return nil)
      delegate = (resolve_delegate_host(task, host, context) rescue return nil)
      # An empty rendered name is labelled with the raw delegate_to: text, as
      # ansible's CallbackBase.host_label does (`fatal: [host -> {{ var }}]`).
      return task.delegate_to if delegate.name.empty?
      delegate != host && delegate.name != "undefined" ? delegate.name : nil
    end

    # Whether the task has any loop source at all - the same set
    # resolve_loop_items_or_raise's block covers. Only used to decide
    # WHERE delegate_to:'s strict-undefined check runs: a looped task may
    # legitimately template delegate_to: from the loop variable, which
    # only exists per item, so the check defers to the per-item
    # resolution site.
    private def task_has_loop_source?(task : Task) : Bool
      !!task.loop_items || !!task.loop_fileglob || !!task.loop_file ||
        !!task.loop_first_found || !!task.loop_template || !!task.loop_flattened ||
        !!task.loop_nested_sources || !!task.loop_together_sources || !!task.loop_subelements_list || !!task.loop_filetree
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
    # ansible-core 2.21 labels EVERY conditional-expression failure with the
    # clause that raised it ("Task failed: A 'when' expression failed: <detail>",
    # live-captured vs 2.21.6; the same clause label rides the [ERROR] chain's
    # "caused by" stanza). 2.19 printed the detail alone.
    WHEN_EXPRESSION_FAILED_PREFIX = "A 'when' expression failed: "

    private def evaluate_when(when_condition : String, vars_context : Hash(String, JSON::Any), host : Host, substitutor : VarSubstitutor? = nil, task : Task? = nil) : Bool
      # Ansible compiles the raw conditional as an expression (no `{{ }}`
      # pre-render), so delimiters outside a string literal are its
      # "Template delimiters are not supported in expressions" syntax
      # error - and the error comes FIRST, before the all-template
      # deprecation below (live-verified vs 2.19.11: `when: 1 >= {{ 1 }}`
      # and `when: "{{ 1 }} == 1"` fatal straight to it with no warning;
      # a whole-template `when: "{{ x }}"` still only deprecates).
      # Checked before substitution, while the delimiters are still
      # visible (chriswayg.mailcow / rockandska.rabbitmq rounds had this
      # engine rendering them away and passing the task).
      if delimiter = ConditionalEvaluator.template_delimiter_error(when_condition)
        raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{delimiter}")
      end
      # Ansible's conditional-as-template deprecation fires while the
      # conditional is being evaluated (see
      # maybe_conditional_delimiters_deprecation) - before the evaluation
      # itself, matching Ansible's warning-then-error order for a non-string
      # whole-template result.
      maybe_conditional_delimiters_deprecation(task, when_condition, "when", vars_context) if task
      maybe_fact_alias_defined_deprecation(task, when_condition, vars_context) if task
      # The play_hosts read deprecation raised while THIS clause evaluates
      # gets its Origin from the clause's own source position (issue #835:
      # bloxberg.corosync_pacemaker's import-line `when: >- ... play_hosts
      # [0] ...` warning pointed at tasks/auth/main.yml:7:9). An
      # import-merged clause carries the import line's when: VALUE token
      # position outright from the parse-time source map
      # (imported_when_origins, else inherited_when_origin); the task's own
      # when: falls back to the same forward "when:" key scan
      # param_value_origin performs for templated params, which also lands
      # on the value token (column 9 for a folded `>-`). Pushed as a STACK
      # site and popped in an ensure so nested evaluations (a lookup inside
      # the condition rendering its own template) restore the outer one.
      if task
        exact_pos = task.imported_when_origins.try { |origins| origins[when_condition]? } ||
                    task.block_inherited_when.try { |inherited| inherited.origins.try { |origins| origins[when_condition]? } } ||
                    task.inherited_when_origin
        # A BLOCK's when: is only ever pre-evaluated here (to decide
        # whether the block runs at all); ansible evaluates it on the
        # block's CHILDREN, so the deprecation a fact-alias read raises
        # belongs after each child's own banner. Registering the clause
        # text only for the children's own evaluations (the block's
        # inherited condition reaches them) keeps the warning where real
        # prints it - the block's skip path emits it separately, after
        # the first child's banner (print_skipped_tasks).
        site_text = task.block? ? nil : when_condition
        if exact_pos
          VarSubstitutor.set_current_when_site(exact_pos[0], exact_pos[1], exact_pos[2], site_text)
        else
          VarSubstitutor.set_current_when_site(task.source_file, task.source_line, 0, site_text)
        end
      end
      begin
        sub = substitutor || VarSubstitutor.new(vars: vars_context, host_name: host.name)
        begin
          substituted_condition = sub.substitute(when_condition)
        rescue ex : VariableSubstitutor::FilterEngine::FilterFailureError
          # A filter that RAN and failed mid-render (first/last on an empty
          # sequence) is a conditional-evaluation failure in real, not the
          # "Syntax error in template:" wording an unresolvable FILTER NAME
          # gets below (live-probed vs 2.19.11: braced `when: "{{ [] | first
          # == 'y' }}"` fails "Task failed: Error while evaluating
          # conditional: No first item, sequence was empty."). A role-local
          # filter's own failure keeps the plugin wording real prints for it
          # (live-probed same session, both when: forms).
          if ex.message.try(&.starts_with?("The filter plugin '"))
            raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{ex.message}")
          end
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Error while evaluating conditional: #{ex.message}")
        rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError | VariableSubstitutor::UnknownTestError
          # The `{{ }}`-wrapped `when:` form compiles its filter/test names
          # during the RENDER (substitute), before the unbraced form's own
          # compile gate below ever runs. Real fails the task there with
          # the rendered-template wording, "Syntax error in template: No
          # filter named 'x'." (live-verified vs 2.19.11, issue #335) -
          # NOT the "Syntax error in expression" wording the unbraced
          # form's gate produces. Unrescued, the raise escaped substitute
          # itself and crashed the whole run instead of failing one task.
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Syntax error in template: #{ex.message}")
        end

        begin
          # strict: true - a task `when:` must end in a real boolean on
          # ansible-core 2.19 (see ConditionalEvaluator#evaluate_truthiness);
          # ANSIBLE_ALLOW_BROKEN_CONDITIONALS relaxes it there and here.
          ConditionalEvaluator.evaluate(substituted_condition, vars_context, strict: true, raise_undefined: true)
        rescue ex : ConditionalEvaluator::ConditionalBooleanError
          # A non-boolean `when:` result gets Ansible's own "Task
          # failed: " prefix, not this method's generic conditional-eval
          # wrapper - verified against ansible-core 2.19.12's exact fatal
          # msg for `when: network_interfaces is defined and network_
          # interfaces` with the var defaulting to `[]` (adfinis-sygroup.
          # network, round 84003): "Task failed: Conditional result (False)
          # was derived from value of type 'list' ... Conditionals must
          # have a boolean result." Only the non-bool-result error class
          # gets this prefix; an undefined reference keeps the familiar
          # "Error while evaluating conditional: " shape (assert:'s own
          # identical split lives in assert_action_plugin.cr).
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{ex.message}")
        rescue ex : RenderExpressionError
          # A Python list-method's runtime failure ("'z' is not in list"):
          # real words it "Task failed: Error rendering expression: <msg>"
          # with the plain prefix and no conditional wrapper (probed vs
          # 2.19.11 2026-10-10, `when: lst.index('z') == 1`).
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Error rendering expression: #{ex.message}")
        rescue ex : ConditionalEvaluator::OrderingTypeError
          # A str-vs-number ordering comparison ('10' >= 1): Python's TypeError
          # is an expression render failure in ansible too, framed the same way
          # as the list-method one above (issue #219).
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Error rendering expression: #{ex.message}")
        rescue ex : Krikri::FilterPluginError
          # A FILTER plugin's runtime failure (e.g. length on None) - real
          # prints its wrapper message with the plain "Task failed: " prefix
          # and NO "Error while evaluating conditional: " (live-verified
          # against 2.19.11 for the mandatory twin). Its cause_text rides the
          # exception so the display can split the wrapper from the cause the
          # way 2.21 does.
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{ex.message}")
        rescue ex : TestPluginError
          # A TEST plugin's runtime failure (the version test's own
          # validation errors: unknown kwargs, strict/version_type
          # conflicts, invalid operators/types, "Version comparison
          # failed: ...") - same framing as the filter case, real prints
          # "The test plugin '...' failed: ..." with the plain "Task
          # failed: " prefix and no conditional wrapper (live-verified
          # against 2.19.11 for the kwargs matrix, round 5210000
          # follow-up: bodsch.icingaweb2's strict=True).
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{ex.message}", ex.cause_text)
        rescue ex : VariableSubstitutor::FilterEngine::FilterFailureError
          # Same FilterFailureError split as the braced-render rescue above:
          # a filter that ran and failed is conditional-evaluation wording
          # for a bare runtime failure (first/last on an empty sequence,
          # live-probed vs 2.19.11 unbraced), the plugin's own message for a
          # raising role-local filter (live-probed same session) - never the
          # "Syntax error in expression:" wording an unresolvable FILTER
          # NAME gets below.
          if ex.message.try(&.starts_with?("The filter plugin '"))
            raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}#{ex.message}")
          end
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Error while evaluating conditional: #{ex.message}")
        rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError | VariableSubstitutor::UnknownTestError
          # A compile-time-rejected filter/test name gets Ansible's own
          # "Syntax error in expression: " wording - Jinja's compiler
          # rejects the name when it COMPILES the template, a different
          # failure class from a runtime conditional-evaluation problem
          # (live-verified vs 2.19.11: `when: x|version_compare(...)`
          # and `when: x is list` both fatal "Task failed: Syntax error
          # in expression: No filter/test named '...'.", found via
          # adarnimrod.apache's assert: version_compare preflight).
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Syntax error in expression: #{ex.message}")
        rescue ex
          raise WhenEvaluationError.new("Task failed: #{WHEN_EXPRESSION_FAILED_PREFIX}Error while evaluating conditional: #{ex.message}")
        ensure
          VarSubstitutor.pop_current_when_site if task
        end
      end
    end

    # A when: LIST is Ansible's own sequence of INDEPENDENT
    # conditionals, each one type-checked for a boolean result separately
    # (live-verified against 2.19.4: `when: [str_var, bool_var]` fails
    # with "Conditional result ... was derived from value of type 'str'"
    # while the equivalent single-string `when: str_var and bool_var`
    # passes - Python's `and` returns the last operand, so only the whole
    # expression's result is type-checked there). The " and "-joined
    # `when_condition` string loses exactly that per-item boundary - the
    # joined expression's result is the LAST clause's value, so a truthy
    # string in an earlier clause was silently accepted
    # (crazikpl.logging's round 400022). Evaluating the retained per-item
    # list (Task#when_condition_list) through the same strict path, in
    # order with early exit on the first false, restores it.
    private def evaluate_when_items(task : Task, vars_context : Hash(String, JSON::Any), host : Host, substitutor : VarSubstitutor? = nil) : Bool
      @last_false_condition = nil
      @last_failed_when_clause = nil
      if items = task.when_condition_list
        items.each do |item|
          begin
            passed = evaluate_when(item, vars_context, host, substitutor, task)
          rescue ex : WhenEvaluationError
            # Real type-checks each clause of a when: LIST (and of a merged
            # import_tasks: when:) for a boolean result INDEPENDENTLY, so the
            # strict failure belongs to ONE clause and the following
            # decorate_conditional_value_origin call must label THAT clause's
            # tested value - the joined task.when_condition string here would
            # point at the when: token instead of the value's defining site
            # (issue #325: an import when-gated on the package manager wrapping
            # a child `when: packages_accept` empty role default labels
            # defaults/main.yml:3:18 in real, not the child task's when:).
            @last_failed_when_clause = item
            raise ex
          end
          unless passed
            @last_false_condition = item
            return false
          end
        end
        true
      else
        condition = task.when_condition.as(String)
        begin
          passed = evaluate_when(condition, vars_context, host, substitutor, task)
        rescue ex : WhenEvaluationError
          @last_failed_when_clause = condition
          raise ex
        end
        @last_false_condition = condition unless passed
        passed
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
    # Ansible consults the task's OWN when: before treating an
    # undefined loop source as fatal.
    #
    #   when: false            + undefined loop -> skip  (scenario 7)
    #   when: item.x is defined + undefined loop -> skip  (`item` is
    #                             unbound, so `is defined` is false)
    #   no when:               + undefined loop -> FAIL  (scenario 1/1b)
    #
    # Note the middle case is why this must NOT be a pre-gate that
    # bails out whenever the condition mentions the loop variable: those
    # conditions are exactly the ones Ansible still evaluates (with
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
    # Ansible's with_items: (unlike loop:) implicitly applies
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
    private def when_passes?(task : Task, vars_context : Hash(String, JSON::Any), host : Host, item_label : String? = nil, shared : VarSubstitutor? = nil, defer_stats : Bool = false, defer_display : Bool = false, item : JSON::Any? = nil, defer_unavailable_module : Bool = false) : Bool
      # Ansible evaluates a non-looped task's `when:` BEFORE it ever
      # attempts to resolve the task's module - so a `when:` that itself
      # raises (an undefined variable, a bad attribute access) is a fatal
      # conditional error even when that same task's module is ALSO
      # unimplemented (round 900000-900999: lukapetrovic-git.azure_ad_app,
      # CyVerse-Ansible.rabbitmq_vhost - ansible-playbook rc=2
      # "Error while evaluating conditional: '...' is undefined", krikri
      # silently skipped). The old code short-circuited an
      # unavailable-module task straight to the skip below without ever
      # evaluating its when:, turning that real fatal into a silent skip.
      # So evaluate strictly here, exactly like the available-module path:
      # a raise propagates to the call site's existing WhenEvaluationError
      # rescue and becomes a real failed task; a clean false takes the
      # normal skip below WITHOUT registering the module (Ansible
      # never reaches module resolution for a when:-false task); only a
      # truthy condition - or no when: at all - counts as genuinely
      # reached for the end-of-run exit-4 accounting.
      #
      # EXCEPT: an unavailable module with a role-private `library/
      # <name>.py` source CAN run - the arbitrary-Python-module runner
      # (PythonModuleRunner) executes it on the target with the target's
      # own python3 - so such a task falls through to normal conditional
      # evaluation and dispatch instead of the skip (Ansible runs
      # these as ordinary Python; the previous unconditional skip
      # diverged on every role leaning on its own library/, seen
      # repeatedly benchmarking linux-system-roles).
      if (module_name = task.unavailable_module) && python_module_source_for(task).nil?
        if task.when_condition.nil? || evaluate_when_items(task, vars_context, host, shared)
          # Ansible finalizes a task's args AFTER its when: evaluates and
          # BEFORE it ever resolves the module - so a genuinely-reached
          # unavailable module must not skip yet when the caller still
          # finalizes args (the solo path passes defer_unavailable_module):
          # an undefined variable in the args is a "Finalization of task
          # args ... failed" fatal there, not a silent skip (round 5210000:
          # centralpayment.rhel-subscription's community.general.
          # redhat_subscription with an undefined redhat_password - krikri
          # skipped, ansible failed the task). Callers that never finalize
          # (batch groups, block includes) keep the in-place skip.
          #
          # The reachable_unavailable_modules registration is CONDITIONAL on
          # the caller now (round 5460184, CiscoUcs.ucs): a deferring caller
          # finalizes args before any module resolution, so its registration
          # moved into execute_task_once after finalization succeeds - a
          # task whose args fail on an undefined variable never reached the
          # module (real's own finalization precedes module resolution and
          # rc is the task failure's 2). An in-place caller (batch groups,
          # block includes - shapes that never finalize here) still counts
          # at its skip.
          reachable_unavailable_modules << module_name unless defer_unavailable_module
          return true if defer_unavailable_module
        end
      else
        return true unless task.when_condition

        return true if evaluate_when_items(task, vars_context, host, shared)
      end

      # Real templates a skipped task's no_log: too, and any core
      # deprecation that templating raises prints before the skipping
      # line - a bare skip that never resolves no_log would hide it
      # (real: `no_log: "{{ '' | bool }}"` under when: false). Loop items
      # are excluded: perform_skip already resolves their no_log.
      if item_label.nil? && task.no_log_expr && !defer_display
        resolve_task_no_log(task, vars_context)
      end
      perform_skip(task, host, item_label, defer_stats, defer_display, item)
      false
    end

    # The skip bookkeeping when_passes? performs for a task whose when:
    # didn't pass (or whose module is unavailable and the caller didn't
    # defer): bump the skipped counter (unless deferred), print the
    # skipping line (unless deferred), register the skipped result.
    # Extracted verbatim from when_passes?'s old bottom half so the
    # deferred unavailable-module skip in execute_task_once performs the
    # identical bookkeeping after arg finalization.
    private def perform_skip(task : Task, host : Host, item_label : String?, defer_stats : Bool, defer_display : Bool, item : JSON::Any?) : Nil
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
        # Ansible only adds the `=> (item=...)` suffix when a loop item exists;
        # with no loop it prints a bare `skipping: [host]` even under no_log
        # (there is no item to censor), while loop items print the censored
        # item because the item can itself be the secret.
        shown = item_label ? (resolve_task_no_log(task) ? "(censored due to no_log)" : item_label) : nil
        suffix = shown ? " => (item=#{shown}) " : ""
        if Krikri::Oneline.enabled?
          # A plain skip renders the bare `host | SKIPPED` line; a loop
          # item's skip line is not rendered at all - the loop finisher's
          # single aggregate line carries the skipped items.
          puts "#{host.name} | SKIPPED".colorize(:cyan) unless item_label
        elsif task.module_name == "_meta"
          # A meta: whose when: was evaluated here follows real's own meta
          # rules: the actions that reject a when: outright print NO
          # skipping line at all, the rest print the meta-shaped dump.
          unless meta_ignores_when?(task)
            puts "skipping: [#{host.name}]#{meta_skip_dump(task, host)}".colorize(:cyan)
          end
        else
          # Same module-keyed -v dump rule the skipped-block printer uses
          # (see skipped_line_suffix_for): a debug: skip's dump is just
          # {false_condition[, item]}, every other module's is the full
          # cleaned skip result (live-verified vs 2.19.11). Identical
          # output at the default verbosity (both shapes are empty there).
          dump_suffix = if debug_module?(task)
                          Krikri::ResultDisplay.skip_line_suffix(task.when_condition, item)
                        else
                          Krikri::ResultDisplay.skip_result_suffix(Krikri::ResultDisplay.skipped_result_dump(task.when_condition), item, task.loop_var)
                        end
          puts "skipping: [#{host.name}]#{suffix}#{dump_suffix}".colorize(:cyan)
        end
      end
      register_skip_result(task, host)
    end

    # Builds the `failed: true` result shape a raised when: evaluation
    # produces, matching Ansible's own "Task failed: Error while
    # evaluating conditional: ..." - for callers (execute_task_once,
    # execute_looped_task_batched) whose return value flows through the
    # normal result pipeline (finish_single_task/finish_looped_task),
    # which already knows how to apply stats/register/halt/ignore_errors:
    # correctly for a real failed result, so building one here instead of
    # hand-rolling that bookkeeping a second time keeps it consistent
    # with every other failure path.
    #
    # `changed: false` IS present - live-verified against ansible-core
    # 2.19.11: a `when:`-raising task with register: gives a registered
    # var carrying changed=false+failed=true+msg. But the FATAL line for
    # a task-level when:/loop-source failure is MODULE-KEYED (round
    # 5310002 follow-up): real 2.19.11 dumps ONLY the msg
    # ("{"msg": "Task failed: ..."}") for a debug: task (live-verified
    # with and without register: and ignore_errors:, the shape round
    # 84003 pinned), while every other module class keeps
    # "changed": false (live sweep over set_fact/file/command/fail/
    # assert/shell/copy/lineinfile/pause/setup/stat/ping/add_host/
    # group_by/include_role/include_tasks/wait_for). The msg-only marker
    # used to be stamped unconditionally here - right for debug, wrong
    # everywhere else - so a failing set_fact now rides WITHOUT it and
    # the generic dump keeps changed (ResultDisplay still strips
    # failed/_ansible_*), while a registered var keeps the full
    # changed+failed+msg shape either way (register strips the marker
    # with every other _ansible_* key).
    private def when_error_result(ex : WhenEvaluationError, task : Task? = nil, host : Host? = nil, loop_item : JSON::Any? = nil, loop_index : Int32? = nil, clause_key : String = "when", clause_raw : String? = nil) : JSON::Any
      # A loop-source typing/lookup failure keeps real's own shape: the
      # bare msg (no "Task failed:" prefix), the module-keyed dump, and
      # the emit_task_error_block suppression marker - see
      # loop_source_error_result's comment (round 5410000).
      return loop_source_error_result(ex, task) if ex.is_a?(LoopTypeError) || ex.is_a?(LoopLookupError)
      msg = ex.message || "Error while evaluating conditional"
      # The loop bindings let a `when: item.<key>` failure carry the
      # failing ITEM's own origin in the msg (ansible's lineage labels
      # the tested item field's defining site, not the task's when:) -
      # each failing loop item's dump differs, like real's.
      msg = decorate_conditional_value_origin(task, msg, host, clause_key: clause_key, clause_raw: clause_raw, loop_item: loop_item, loop_index: loop_index) if task
      fields = {"changed" => false, "failed" => true, "msg" => msg}
      # A filter/test plugin's own cause rides along for the [ERROR]
      # block's extra record (see WhenEvaluationError#cause_text).
      if cause = ex.cause_text
        fields["_ansible_conditional_cause"] = cause
      end
      fields["_ansible_task_error_msg_only"] = true if task && debug_module?(task)
      # A conditional-EVALUATION failure's [ERROR] chain was already
      # emitted by emit_when_error_chain on the catch site - the marker
      # (like loop_error_result's) keeps ResultDisplay's generic failure
      # block from printing a second, differently-shaped one. Var-render
      # failures stay unmarked: their pre-existing display shape IS the
      # generic path's.
      fields["_ansible_when_error_emitted"] = true if conditional_evaluation_failure?(msg)
      JSON.parse(fields.to_json)
    end

    # A loop-source / loop-item templating failure's result: the same
    # task-level shape as when_error_result, plus a marker telling
    # ResultDisplay the [ERROR] chain block was already printed by
    # emit_loop_error_chain (its shape - "Task failed." + the value's own
    # defining Origin - is not what the generic failure display builds).
    private def loop_error_result(ex : WhenEvaluationError, task : Task? = nil) : JSON::Any
      result = when_error_result(ex, task)
      hash = result.as_h.dup
      hash["_ansible_loop_error_emitted"] = JSON::Any.new(true)
      JSON.parse(hash.to_json)
    end

    # For a `when_passes?` call site with no real per-item result
    # pipeline to flow a `WhenEvaluationError` through (a bare `meta:`
    # check, an `include_vars:` solo check, a mixed-task batch group
    # member) - replicates exactly what `when_passes?` itself used to do
    # inline before it started raising instead: stats/halt/register/
    # print, respecting `ignore_errors:` the same way `ResultDisplay.
    # update_stats` treats an ignored failure everywhere else (ok+=1 AND
    # ignored+=1, not failed+=1, host not halted - verified directly
    # against a ansible-playbook run: `ignore_errors: true` on a
    # when:-raising task prints "...ignoring" and continues with `ok=2
    # ... ignored=1`, exit 0). Always returns `false`, the same "don't
    # run this task" signal every caller already treats a when:-skip as.
    private def swallow_when_error(task : Task, host : Host, ex : WhenEvaluationError, item_label : String? = nil, defer_stats : Bool = false, defer_display : Bool = false, emit_chain_for_item : Bool = false, loop_item : JSON::Any? = nil) : Bool
      msg = decorate_conditional_value_origin(task, ex.message || "Error while evaluating conditional", host)
      ignore_errors = resolve_task_ignore_errors(task, host: host)
      # A delegated task's fatal/failed lines carry the `-> delegate`
      # label even when the failure happened before any result pipeline
      # ran (CallbackBase.host_label reads the task keyword) - real
      # prints `fatal: [host -> delegate]`, not `fatal: [host]`.
      delegate_target = delegate_display_target(task, host)
      host_label = delegate_target ? "#{host.name} -> #{delegate_target}" : host.name
      unless defer_stats
        if ignore_errors
          @results[host.name]["ok"] += 1
          @results[host.name]["ignored"] += 1
        else
          @results[host.name]["failed"] += 1
        end
      end
      book_failure_halt(host) unless ignore_errors
      suffix = item_label ? " => (item=#{item_label})" : ""
      # A loop-source typing/lookup failure rides this no-result-pipeline
      # path (include_tasks:/include_role:'s own loop funnel): real's
      # block + fatal are distinct - the [ERROR] block from
      # emit_loop_source_error_block and a dump carrying the BARE msg (no
      # "Task failed:" prefix), not the chain shape (live-verified vs
      # 2.19.11, round 5410000). The dump's changed key is module-keyed
      # exactly as on the result-pipeline path (see
      # loop_source_error_result): every module but debug: carries
      # "changed": false (live-verified vs 2.21.6, issue #987), debug:
      # dumps the msg alone.
      if ex.is_a?(LoopTypeError) || ex.is_a?(LoopLookupError)
        unless defer_display
          if Krikri::Oneline.enabled?
            # The oneline callback's failed shape for the no-result
            # pipeline path: the synthesized-exception line plus the
            # FAILED! dump (same payload the fatal line carries).
            payload = debug_module?(task) ? {"msg" => msg} : {"changed" => false, "msg" => msg}
            puts Krikri::Oneline.exception_line("(traceback unavailable)").colorize(:red)
            puts "#{host.name} | FAILED! => #{ResultDisplay.dump_oneline_json(JSON.parse(payload.to_json))}".colorize(:red)
          else
            emit_loop_source_error_block(task, ex)
            if debug_module?(task)
              puts "fatal: [#{host_label}]#{suffix}: FAILED! => {\"msg\": #{msg.to_json}}".colorize(:red)
            else
              puts "fatal: [#{host_label}]#{suffix}: FAILED! => {\"changed\": false, \"msg\": #{msg.to_json}}".colorize(:red)
            end
            puts "...ignoring".colorize(:red) if ignore_errors
          end
          register_name = task.register
          unless register_name.nil? || register_name.empty?
            register_result(host, register_name, JSON.parse({
              "failed" => true,
              "msg"    => msg,
            }.to_json))
          end
        end
        # Same "ran" credit as the below pipeline: a loop-source failure
        # booked a failed result for this host.
        mark_role_dep_ran(task, host)
        return false
      end
      unless defer_display
        # no_log is a task-level security control: the conditional's
        # error text embeds the rendered condition, which can quote
        # variable values the task asked to keep out of the output.
        # Ansible stamps _ansible_no_log onto these action failures and
        # shows the censored JSON - mirror that shape here.
        if Krikri::Oneline.enabled?
          # A looped task's per-item when-failure prints nothing here -
          # the loop's aggregate line carries it.
          unless item_label
            if resolve_task_no_log(task)
              puts "#{host.name} | FAILED! => #{ResultDisplay.dump_oneline_json(JSON.parse({"censored" => "the output has been hidden due to the fact that 'no_log: true' was specified for this result"}.to_json))}".colorize(:red)
            else
              display_msg = msg.starts_with?("Task failed: ") ? msg : "Task failed: #{msg}"
              payload = debug_module?(task) ? {"msg" => display_msg} : {"changed" => false, "msg" => display_msg}
              puts Krikri::Oneline.exception_line("(traceback unavailable)").colorize(:red)
              puts "#{host.name} | FAILED! => #{ResultDisplay.dump_oneline_json(JSON.parse(payload.to_json))}".colorize(:red)
            end
          end
        elsif resolve_task_no_log(task)
          suffix = item_label ? " => (item=(censored due to no_log))" : ""
          puts %(fatal: [#{host_label}]#{suffix}: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result"}).colorize(:red)
        elsif conditional_evaluation_failure?(msg)
          # ansible-core 2.19.11 (live-captured): a conditional-
          # evaluation failure prints a two-level [ERROR] chain block on
          # stdout BEFORE the fatal line, and the fatal line itself is the
          # result JSON {"changed": false, "msg": "Task failed: ..."} - the
          # error message prefixed with "Task failed: " - not the bare
          # message. A looped task's per-item failure lines use Ansible's
          # loop-failure shape instead of the solo fatal: one
          # (`failed: [host] (item=N) => {...}` - item BEFORE the =>),
          # with the chain printed once per task, before the items.
          # A looped include_tasks' caller opts in per item
          # (emit_chain_for_item) so the chain lands once, before the
          # FIRST failing item's line - ansible prints the block before
          # the per-item lines even for a looped include (issue #627);
          # include_role's looped per-item shape keeps its existing
          # no-chain display.
          if item_label
            if emit_chain_for_item && @item_when_chain_emitted.add?({task.object_id, host.name})
              emit_when_error_chain(task, msg, host, cause_text: ex.cause_text)
            end
          else
            emit_when_error_chain(task, msg, host, cause_text: ex.cause_text)
          end
          display_msg = msg.starts_with?("Task failed: ") ? msg : "Task failed: #{msg}"
          if item_label
            # Ansible's loop-item failed dump carries the loop bindings
            # (ansible_loop_var + the item under the loop var's name) for
            # a looped include_tasks too - live-verified 2.19.11:
            # {"ansible_loop_var": "loop_repository", "changed": false,
            # "loop_repository": {...}, "msg": "Task failed: ..."} (issue
            # #627). A looped plain module task's when:-failed dump does
            # NOT carry them, so this stays keyed on the include path's
            # own opt-in (loop_item), not on item_label alone.
            if loop_item && (loop_var_name = task.loop_var || "item")
              dump = {
                "ansible_loop_var" => JSON::Any.new(loop_var_name),
                "changed"          => JSON::Any.new(false),
                loop_var_name      => loop_item,
                "msg"              => JSON::Any.new(display_msg),
              } of String => JSON::Any
              puts "failed: [#{host_label}] (item=#{item_label}) => #{ResultDisplay.python_json_dump(JSON::Any.new(dump))}".colorize(:red)
            else
              puts "failed: [#{host_label}] (item=#{item_label}) => {\"changed\": false, \"msg\": #{display_msg.to_json}}".colorize(:red)
            end
          elsif debug_module?(task)
            # Task-level conditional failures on a debug: dump the msg
            # alone - real 2.19.11 shows {"msg": "Task failed: ..."} with
            # no changed key (live-verified; see when_error_result).
            puts "fatal: [#{host_label}]: FAILED! => {\"msg\": #{display_msg.to_json}}".colorize(:red)
          else
            # Every other module class keeps changed: false in the same
            # dump (live-verified, module-keyed; see when_error_result).
            puts "fatal: [#{host_label}]: FAILED! => {\"changed\": false, \"msg\": #{display_msg.to_json}}".colorize(:red)
          end
        else
          puts "fatal: [#{host_label}]#{suffix}: FAILED! => #{msg}".colorize(:red)
        end
        puts "...ignoring".colorize(:red) if ignore_errors && !Krikri::Oneline.enabled?
      end
      register_name = task.register
      unless register_name.nil? || register_name.empty?
        # Same changed-carrying shape as when_error_result: Ansible's
        # registered var for a conditional-evaluation failure carries
        # changed=false+failed=true+msg (live-verified, ansible-core
        # 2.19.11).
        register_result(host, register_name, JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => msg,
        }.to_json))
      end
      # A conditional-evaluation failure booked a real result (failed, or
      # ok+ignored behind ignore_errors:) - it counts as "ran" for the
      # per-host dependency dedup the same way any non-skipped result
      # does (issue #320).
      mark_role_dep_ran(task, host)
      false
    end

    # A skipped task's own register: still gets set (to a `changed:
    # false, skipped: true` result, matching Ansible) rather than
    # left holding whatever a previous task/loop iteration happened to
    # register under the same name. Without this, dev-sec os_hardening's
    # `register: mountpoint` / `when: mountpoint.changed` pair (each
    # include_tasks loop iteration reusing the same register name) leaks
    # a *prior* iteration's real "changed" result into a later iteration
    # whose own task was skipped, wrongly running the dependent task.
    private def print_batched_skip(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Nil
      puts Krikri::Oneline.skip_line(host.name, Krikri::ResultDisplay.skip_line_suffix(task.when_condition)).colorize(:cyan)
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
      # An unresolvable connection type must take the solo path, where
      # execute_task_once's own check fails the task like Ansible -
      # the batch script would silently SSH instead.
      return {false, nil} if (conn_type = vars_context["ansible_connection"]?.try(&.as_s?)) &&
                             PluginManager.connection_plugin_not_found?(conn_type)
      # A templated action:/local_action: resolves its Ansible module only
      # inside execute_task_once; the batch script path has no such
      # resolution (and breaks_run? below only keeps the task out of
      # NEIGHBORS' groups - it would still batch as its own size-1
      # group), so it always takes the solo path.
      return {false, nil} if task.templated_action
      # fetch:/wait_for_connection: must run on the controller (see
      # TaskBatcher.runs_on_the_controller? for the remote-step hazard).
      # breaks_run? keeps them out of a remote group, but their own size-1
      # group would still be emitted as a remote step here - so the runner
      # sends them solo too, where execute_task_once dispatches them
      # controller-side via PluginManager's own controller-only path.
      return {false, nil} if PluginManager.controller_only?(task.module_name)

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
      result = cache.delete(task).try(&.[0])
      # Same "when the task is reached, not at batch-build time" rule for
      # the output captured during when: evaluation and step preparation
      # (issue #489's warnings, issue #979's read deprecations): the
      # consumed entry's text prints here, under this task's own banner
      # just before its result display; entries for never-reached tasks are
      # never printed.
      if host_warnings = @batch_captured_warnings[host.name]?
        if captured = host_warnings.delete(task)
          captured.emit
        end
        @batch_captured_warnings.delete(host.name) if host_warnings.empty?
      end
      # A when: that raised while the group was being built was cached
      # without its [ERROR] chain: ansible prints that block just before the
      # task's fatal line, so it is emitted here, when the task is reached,
      # not at batch-build time (which would precede earlier members' output).
      if result && result["failed"]?.try(&.as_bool?) == true &&
         (msg = result["msg"]?.try(&.as_s?)) && conditional_evaluation_failure?(msg)
        emit_when_error_chain(task, msg, host, cause_text: result["_ansible_conditional_cause"]?.try(&.as_s?))
      end
      {true, result}
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
      # The connection settings the first BatchScript step resolved to -
      # every later step must match it or the group cannot share one SSH
      # round trip (a batch script is ONE connection: user/port/key/
      # password/args differences would silently run later members over
      # the FIRST member's connection).
      first_step_conn : ConnectionSettings? = nil

      group.each do |task|
        break if halted

        vars_context = if task == trigger_task && (reused = trigger_vars_context)
                         reused
                       else
                         begin
                           build_vars_context(task, host)
                         rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError
                           # Same degrade-to-one-clean-failed-task shape as
                           # execute_task's own build_vars_context rescue: the
                           # member's own vars: block used an unknown filter,
                           # Ansible fails just that task with "No filter
                           # named 'X'." - cache the failed result so the
                           # consumer reports it instead of the process
                           # crashing out of execute_batch_group entirely.
                           cache[task] = {when_error_result(WhenEvaluationError.new(ex.message || "Failed to render task vars"), task, host), Hash(String, JSON::Any).new}
                           # This member is a hard failure, so Ansible's play stops
                           # here: later members must not join the round trip (see
                           # the when-rescue below for the issue #649 shape). No
                           # vars_context exists to resolve a templated
                           # ignore_errors: against - the parse-time value stands.
                           halted = true unless task.ignore_errors?
                           next
                         end
                       end

        # Same sharing as the solo path: when: and the step preparation
        # both read this member's identical vars_context.
        member_substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

        # Batch-build looks at every member up front - its when: is
        # evaluated and its action prepared (a template: renders on the
        # controller) - so anything that emits stderr does it here, ahead of
        # the members that really run: issue #489's authorized_key
        # jinja-constant warning, and an INJECT_FACTS_AS_VARS or play_hosts
        # read in a later member's when: or template (issue #979).
        # Real only emits when the task is actually reached, so capture the
        # whole window and let try_batched_result emit it when it consumes
        # the task; a member a halt keeps from ever being reached never
        # emits, and its held-back deprecation does not spend the run's
        # per-origin dedupe either.
        member_state = :run
        outcome = nil
        captured = ResultDisplay.capture_stderr do
          begin
            # defer_stats + defer_display: a when:-skipped batch member has
            # its skipped counter AND its "skipping:" print both deferred -
            # the counter aggregates at the task level, and the print is
            # emitted by execute_task when it consumes this nil from the
            # cache, so each group member's skip prints under its own banner
            # rather than all at once here during batch-build.
            member_state = :skip unless when_passes?(task, vars_context, host, shared: member_substitutor, defer_stats: true, defer_display: true)
          rescue ex : WhenEvaluationError
            cache[task] = {when_error_result(ex, task, host), vars_context}
            # A member whose when: RAISED is a failed task, not a skipped
            # one, and Ansible aborts the play at it - so the group's
            # remaining members must never reach the target. Without this
            # the round trip still dispatched them: tumf.docker-compose's
            # `when: ver|failed` (issue #649) failed the Remove Old Version
            # task, yet the group's next member - Install Docker Compose's
            # get_url - ran anyway and left a real docker-compose binary on
            # the host, so krikri's warm phase stat-ed a file ansible's warm
            # phase never created (skipping vs ok). The solo path gets this
            # for free: finish_single_task halts the host before the
            # consumer reaches later tasks, while a batch build executes
            # every member it adds.
            halted = true unless resolve_task_ignore_errors(task, vars_context, host)
            member_state = :when_raised
          end
          outcome = prepare_batch_step(task, host, vars_context, shared: member_substitutor) if member_state == :run
        end
        (@batch_captured_warnings[host.name] ||= Hash(Task, ResultDisplay::CapturedStderr).new)[task] = captured unless captured.empty?

        if member_state == :when_raised
          next
        elsif member_state == :skip
          cache[task] = {nil, vars_context}
          next
        end

        case step_outcome = outcome
        when JSON::Any
          cache[task] = {step_outcome, vars_context}
          failed = step_outcome["failed"]?.try(&.as_bool) || false
          halted = true if failed && !resolve_task_ignore_errors(task, vars_context)
        when BatchScript::Step
          member_conn = ConnectionSettings.resolve(host, vars_context)
          if first = first_step_conn
            if member_conn.fingerprint != first.fingerprint
              # A member whose effective connection differs from the
              # group's first step cannot share the round trip: run it
              # through the exact solo path instead (execute_task_once
              # applies changed_when:/failed_when: like the batch path
              # does after interpretation), and cache its result here -
              # the task-major consumer reads this cache either way.
              # Its when: was already checked above and passed; the
              # re-check inside execute_task_once re-passes on identical
              # vars without any counter effect.
              if result = execute_task_once(task, host, vars_context, shared: member_substitutor)
                cache[task] = {result, vars_context}
                # Mirror the JSON::Any branch's halting: a failed (and not
                # ignored) detour member stops later members of the group
                # exactly as a failed batch step would have.
                failed = result["failed"]?.try(&.as_bool) || false
                halted = true if failed && !resolve_task_ignore_errors(task, vars_context)
              else
                cache[task] = {nil, vars_context}
              end
              next
            end
          else
            first_step_conn = member_conn
          end
          steps << step_outcome
          step_tasks << task
          step_vars << vars_context
        end
      end

      return if steps.empty?

      conn = ConnectionSettings.resolve(host, step_vars.first)
      step_results = run_batch_steps(host, conn, steps, vars: step_vars.first)

      steps.each_index do |idx|
        next unless interpreted = step_results[idx]?

        task = step_tasks[idx]
        vars_context = step_vars[idx]
        # Same invocation.module_args attach the non-batched path does inside
        # execute_task_once - a batched task's REGISTERED result needs the
        # block exactly as much as a solo one (Turgon37.ssh_server reads
        # `item.invocation.module_args.creates` out of registered results),
        # and it silently didn't exist here: pre-strict templates read it as
        # an undefined value, 2.19-parity strictness fails the task on it.
        interpreted = attach_batch_step_invocation(task, steps[idx], interpreted, InvocationInjection.enabled?(vars_context))
        interpreted = shape_script_result(task, interpreted)
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
    private def run_batch_steps(host : Host, conn : ConnectionSettings, steps : Array(BatchScript::Step), vars : Hash(String, JSON::Any)? = nil) : Hash(Int32, JSON::Any)
      # ansible fails a become task whose temp files root cannot chown to
      # the become user; steps from that one on never run (fail-fast).
      steps.each_with_index do |step, bad|
        failure = PluginManager.become_chown_probe_failure(conn, !step.become_user.nil?, step.become_user)
        next unless failure
        head = bad > 0 ? run_batch_steps(host, conn, steps[0, bad], vars) : Hash(Int32, JSON::Any).new
        head[bad] = failure
        return head
      end

      if result = try_daemon_batch(host, conn, steps, vars)
        return result
      end

      interpreted = interpret_batch_script(host, conn, steps)

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
      # Re-sending the whole group after a missing binary was wrong: the
      # script fail-fasts at the missing step, so every step before it
      # already ran on the target, and running those again repeats their
      # side effects (a `file:` step reports ok on its second run because
      # the first run created the directory). Only the missing step and the
      # steps that never ran are sent again.
      ssh_user = conn.user
      resend = PluginManager.batch_steps_to_resend(interpreted, steps.map(&.module_name), ssh_user)
      return interpreted if resend.empty?

      # The re-upload this recovery performs fails exactly like any
      # other upload when the host has gone unreachable mid-play -
      # convert that to UNREACHABLE results for the steps being re-sent
      # (the same conversion execute_remote_plugin applies to its own
      # lazy-upload path) instead of letting the exception kill the
      # run. Any other exception still propagates.
      begin
        PluginManager.recover_missing_plugins!(host, resend.map { |idx| steps[idx].module_name }.uniq!, host.vars)
      rescue ex
        raise ex unless SSHManager.connection_level_exception?(ex)
        detail = ex.message.to_s.lines.first?.to_s
        unreachable = JSON.parse({
          "changed"     => false,
          "msg"         => SSHUnreachableMsg.unreachable_msg(detail, host.vars, host),
          "stderr"      => detail,
          "unreachable" => true,
        }.to_json)
        resend.each { |idx| interpreted[idx] = unreachable }
        return interpreted
      end

      resent = interpret_batch_script(host, conn, resend.map { |idx| steps[idx] })
      resend.each_with_index do |idx, pos|
        if result = resent[pos]?
          interpreted[idx] = result
        else
          interpreted.delete(idx)
        end
      end
      interpreted
    end

    private def interpret_batch_script(host : Host, conn : ConnectionSettings, steps : Array(BatchScript::Step)) : Hash(Int32, JSON::Any)
      script_results = run_batch_script(host, conn, steps)
      interpreted = Hash(Int32, JSON::Any).new
      script_results.each do |idx, step_result|
        step = steps[idx]
        become = !step.become_user.nil?
        # ansible fails the task itself when the connection user is root
        # and the become_user does not exist (see become_chown_failure_result);
        # the batch path must word it the same way the one-shot
        # PluginManager path does, before the generic parse gets a look in.
        failure = if PluginManager.become_needed?(become, step.become_user, conn.user)
                    PluginManager.become_chown_failure_result(step_result.exit_code, step_result.stderr, step.become_user, conn.user)
                  end
        interpreted[idx] = failure || PluginManager.interpret_remote_result(step_result.exit_code, step_result.stdout, step_result.stderr)
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
    # re-sent as a script. That re-execution window is now WIDER than the
    # solo daemon path's, which narrows it to "the request never went
    # out" and fails the task instead when a dispatched request's
    # response was lost (SSHManager::DaemonDispatchUnknownError - a
    # module that ran but reported nothing must not be re-run). The batch
    # path still re-sends on ANY failure, deliberately: the alternative
    # is leaving those members with no cache entry at all, which
    # execute_batch_group's contract reads as "skipped", silently NOT
    # running tasks the playbook asked for. A wrongly-repeated
    # idempotent module is a far better failure than a silently dropped
    # one.
    private def try_daemon_batch(host : Host, conn : ConnectionSettings, steps : Array(BatchScript::Step), vars : Hash(String, JSON::Any)? = nil) : Hash(Int32, JSON::Any)?
      return nil unless PluginManager.daemon_enabled?
      return nil if steps.empty?

      become_user = steps.first.become_user
      return nil unless steps.all? { |step| step.become_user == become_user }
      # A login-shell escalation only the script transport's per-step sudo
      # wrapper honours (the daemon spawns once under plain `sudo -n -u`,
      # with no become_flags ever reaching sudo) must not take the daemon.
      return nil if steps.any? { |step| PluginManager.become_login_shell?(step.become_flags) }
      return nil if steps.any?(&.module_name.empty?)

      ssh_user = conn.user
      return nil if SSHManager.daemon_unavailable?(conn.conn_host, ssh_user, conn.port, become_user,
                      SSHManager.connection_sig(conn.identity_file, conn.ssh_extra_options, Passwords.connection(vars, host)))

      payload = steps.map do |step|
        {
          module_name:   step.module_name,
          config:        JSON.parse(step.config_json),
          ignore_errors: step.ignore_errors?,
        }
      end

      begin
        results = SSHManager.daemon_send_batch(
          conn.conn_host,
          ssh_user,
          conn.port,
          "#{PluginManager.remote_plugin_dir(ssh_user)}/#{steps.first.module_name}",
          payload,
          identity_file: conn.identity_file,
          become_user: become_user,
          become_password: Passwords.become(vars, host),
          extra_args: conn.ssh_extra_options
        )
        # Same normalization the script transport applies one frame up in
        # interpret_batch_script: the daemon's parsed response is a raw
        # module wire result, and a SUCCESSFUL module's wire JSON carries
        # no "failed" key at all (BasePlugin#to_json omits it, exactly
        # like Ansible's module protocol - the CONTROLLER backfills
        # failed: false). Found via round 813096 (also 813254/813290/
        # 813354, one root cause: ~/scratch/krt-results/
        # 813096_atlantic_elan_monitoring_blackbox_exporter/): a
        # daemon-batched successful slurp: registered a dict with no
        # "failed" key, and the elan.monitoring_* roles' sibling block
        # condition `when: registered["failed"] or ...` then died with
        # "object of type 'dict' has no attribute 'failed'" once per loop
        # item on the warm run, where ansible-playbook skips the
        # block. The daemon-side run_batch backfills too, so this is
        # belt-and-suspenders against a stale pre-fix daemon binary still
        # resident on a remote host - but it is what makes this path
        # shape-identical to interpret_batch_script by construction.
        results.each do |idx, result|
          results[idx] = PluginManager.normalize_module_result(result)
        end
        results
      rescue
        nil
      end
    end

    private def run_batch_script(host : Host, conn : ConnectionSettings, steps : Array(BatchScript::Step)) : Hash(Int32, BatchScript::StepResult)
      batch_id = Random::Secure.hex(8)
      script = BatchScript.build(batch_id, steps, conn.user)
      raw = SSHManager.exec_script(conn.conn_host, conn.user, script, conn.port, identity_file: conn.identity_file, extra_args: conn.ssh_extra_options)
      parsed = BatchScript.parse(raw[:stdout])

      # The batch transport only ever sees the SSH invocation's STDOUT -
      # BatchScript.parse reads nothing else - so a host the SSH
      # transport itself cannot reach comes back as an EMPTY parse (no
      # step ran, and ssh's own "ssh: connect to host ..." evidence sits
      # in stderr where this path used to drop it). Every member of the
      # group would then be silently treated as skipped instead of
      # failing. When nothing ran AND the stderr names the transport,
      # hand every step the same failure so interpret_remote_result -
      # via the shared pattern list - stamps it unreachable like the
      # solo path does. A batch that RAN (any step has a result) is left
      # untouched: its per-step rc/stdout/stderr are the real evidence.
      if parsed.empty? && SSHManager.connection_level_failure?(raw[:exit_code], raw[:stderr], raw[:stdout])
        steps.each_index do |idx|
          parsed[idx] = BatchScript::StepResult.new(raw[:exit_code], raw[:stdout], raw[:stderr])
        end
      end

      # A batch script that COMPLETED always exits 0 (a failing step
      # dumps and exits 0; the staging-safety refusals exit 75), so an
      # ssh-level 255 means the TRANSPORT died mid-script. Per-step
      # results are streamed as they complete (see BatchScript.build),
      # so the steps that finished before the death are already in the
      # captured stdout and #parse recovers them - real Ansible, which
      # runs every task as its own ssh round trip, books those completed
      # tasks as ok (live-verified on Atlantic.net, probe role
      # kop_sshd_batch vs ansible-core 2.19.11, 2026-10-08: real recapped
      # `ok=2 unreachable=1` - gather_facts plus the pre-death task -
      # while this engine recapped `ok=1`, having lost the completed
      # step with the dead transport). Only the steps whose results
      # never arrived get the transport's own evidence as a synthetic
      # StepResult, which interpret_remote_result classifies as
      # UNREACHABLE - without this they would have no cache entry at
      # all, which execute_batch_group's contract reads as "skipped",
      # silently NOT running tasks the playbook asked for.
      BatchScript.stamp_missing_on_transport_death(parsed, raw[:exit_code], raw[:stderr], steps.size)
      # The transport-death stamping only answers ssh's own 255; the
      # script's OWN pre-step aborts (the staging-safety refusals' exit
      # 75, a full disk failing the batch dir's mkdir) leave every step
      # resultless too, and would silently skip the whole group - see
      # stamp_missing_on_nonzero_exit for the round that exposed it.
      BatchScript.stamp_missing_on_nonzero_exit(parsed, raw[:exit_code], raw[:stderr], steps.size)

      parsed
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
    # one, otherwise the run-wide `--check` flag. Ansible honours
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

      # Ansible templates the become_user keyword before any module arg is
      # finalized, so an undefined keyword reports its own error even when
      # an arg is undefined too.
      substituted_become_user = begin
        resolve_task_become_user(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end
      substituted_become_flags = begin
        resolve_task_become_flags(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end

      # Ansible post-validates the become keyword before it finalizes the
      # task args, so a templated become: that renders to a non-bool fails
      # with its own keyword error even when an arg is also undefined
      # (issue #465) - arg templating used to win with the wrong error.
      if task.become_expr
        begin
          resolve_task_become_flag(task, host, vars_context, substitutor)
        rescue ex : UndefinedVariableError
          return keyword_failure_json(ex, task)
        end
      end

      # Issue #735: ansible post-validates the diff:/check_mode: bool
      # keywords the same way, so a value boolean() refuses fails the
      # task with its own keyword error before any arg templating.
      if error = boolean_keyword_invalid_error(task, vars_context)
        return keyword_failure_json(error, task)
      end

      # Same no_log keyword-templating probe as execute_task_once (issue
      # #317): the batched remote path must fail the task identically
      # instead of sending it to the remote code while masked.
      if undefined = no_log_keyword_undefined_error(task, vars_context)
        return no_log_keyword_failure_json(task, undefined)
      end

      begin
        substitute_block_name_chain(task, substitutor)
        substituted_params = expand_templated_args(substitute_task_params(task.params, substitutor, native_containers: task.module_name.ends_with?("set_fact"), module_name: task.module_name, task: task), substitutor, task)
        substituted_env = substitute_task_environment(task, substitutor)
      rescue ex : BlockNameKeywordError
        # A block name's strict-undefined failure is a KEYWORD failure in
        # ansible (the child fails at "Error processing keyword 'name'"),
        # not a task-arg finalization one - its own three-link chain, no
        # "Finalization of task args" middle link.
        return block_name_keyword_failure_json(ex, task)
      rescue ex
        # Same "finalization of task args failed" handling as
        # execute_task_once's own identical rescue (see there) - this
        # batched-path call site had no equivalent before, so a strict:
        # UndefinedVariableError (or a lookup('url', ...) HTTP failure,
        # the pre-existing case this class of rescue was built for) would
        # have crashed the whole run instead of failing just this task.
        # Same [ERROR] chain block + changed: false as
        # execute_task_once's identical rescue (2.19.11 live-captured).
        failed = finalization_failure_json(ex, task)
        # Stash, don't print: batch-build prepares every member up front,
        # BEFORE the earlier members' results display - an inline print
        # here put the block ahead of the previous task's changed: line
        # (issue #14, pylabs.nginx). The display path prints it under this
        # task's own banner, just before the fatal line.
        if ex.is_a?(UndefinedVariableError) && (text = finalization_error_block_text(task, ex, host, vars_context))
          TaskExecutor.stash_finalization_error_block(failed, text)
        end
        # Not routed through apply_changed_failed_when - same reasoning as
        # execute_task_once's identical rescue: failed_when:/changed_when:
        # only reinterpret a MODULE result, and no module ran here.
        return failed
      end

      warn_groupby_storage(task)
      warn_markup_storage(task)
      substituted_params = resolve_role_relative_src(task, substituted_params)
      # Same pre-inline copy src+content gate as execute_task_once (see
      # there) - the batched path must fail identically.
      if violation = copy_src_content_conflict(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      if violation = copy_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      copied = inline_copy_source_content(task, substituted_params, host, vars_context)
      if copied.is_a?(JSON::Any)
        return apply_changed_failed_when(task, copied, vars_context, host)
      end
      substituted_params = copied
      # Ansible's unarchive/assemble action plugins crash on non-string
      # literal args at their own controller-side touch points, before
      # the src staging paths could leak the marker into a message or
      # upload path - see unarchive_assemble_literal_type_failure.
      if violation = unarchive_assemble_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      staged = stage_unarchive_remote_src(task, substituted_params, host, vars_context)
      if staged.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged, vars_context, host)
      end
      substituted_params = staged
      staged_script = stage_script_src(task, substituted_params, host, vars_context)
      if staged_script.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged_script, vars_context, host)
      end
      substituted_params = staged_script
      staged_assemble = stage_assemble_dir(task, substituted_params, host, vars_context)
      if staged_assemble.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged_assemble, vars_context, host)
      end
      substituted_params = staged_assemble

      # Action-only directives: pre-action validation gate (see
      # execute_task_once's identical hook).
      if violation = argspec_validation_result(task, substituted_params, vars_context, action_level_only: true, check_mode: resolve_task_check_mode(task, vars_context))
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible's assemble action expands the destination's user path itself
      # after the fragments are staged and before the copy module ever
      # validates anything - so a non-string literal dest crashes the
      # action instead of failing the copy spec. See
      # assemble_dest_expand_failure.
      if violation = assemble_dest_expand_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible's dest expand crash fires only after the src lookup succeeded
      # - here that is after inline_copy_source_content above - and after
      # the required-argument checks (see execute_task_once's identical
      # hook placement).
      if violation = copy_dest_expand_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible's add_host: the name failure / groups failure (action stage)
      # and the inventory.add_host name crash (result-processing stage,
      # which aborts the whole run) - see add_host_literal_type_failure.
      # Same hook as execute_task_once's own, for the batched path.
      if violation = add_host_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible validates the become: keyword for every task before any
      # action plugin runs, so a non-boolean templated become: fails debug:
      # and the other controller-side actions too (issue #143).
      begin
        resolve_task_become(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end

      # The gather_facts action's own `parallel:` conversion runs inside the
      # action plugin, i.e. after the become: keyword check and before any
      # fact module - see gather_facts_parallel_failure.
      if violation = gather_facts_parallel_failure(task, substituted_params, vars_context)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      if ActionPluginManager.has_action_plugin?(task.module_name)
        # task_host is the TASK's own host, passed only when delegate_to: is
        # in play - synchronize's dest_is_local branch (delegate_to naming
        # the task's own host) must not fire for a plain remote task, or the
        # module binary gets dispatched ONTO the target host and pull mode
        # rsyncs a controller-only dest path there (softasap.sa-vpn-softether
        # round 2300304: "mkdir /home/labros/... failed: No such file or
        # directory"). Batchable tasks never carry delegate_to:, so this is
        # nil in practice here.
        action_result = ActionPluginManager.execute_action(task.module_name, substituted_params, vars_context, host, @inventory, task.delegate_to ? host : nil, resolve_task_check_mode(task, vars_context), nil, task.action_name)
        emit_assert_that_deprecations(task, substituted_params, action_result, vars_context)

        unless action_result.success?
          failed = {
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }
          # An ACTION-level failure (a bare AnsibleActionFail raised by
          # the plugin itself) renders without the "Module failed." chain
          # segment - see ActionResult#action_level. A crash_failure's msg
          # is Ansible's own "Task failed: <exception>" wrapper while its
          # [ERROR] block text stays bare - see ActionResult#error_detail.
          failed["_ansible_action_level"] = true if action_result.action_level?
          if detail = action_result.error_detail?
            failed["_ansible_error_detail"] = detail
          end
          if err_origin = action_result.error_origin?
            failed["_ansible_error_origin"] = err_origin
          end
          if undef_origin = undef_chain_result_origin(task, action_result, host)
            failed["_ansible_undef_chain_origin"] = undef_origin
          end
          result_json = JSON.parse(failed.to_json)
          Krikri.mark_failed_key_order(result_json, FAILED_KEY_ORDER_MSG_FIRST)
          return apply_changed_failed_when(task, result_json, vars_context, host)
        end

        bump_hv_generation_for_add_host(task.module_name)

        # debug:/assert:/fail:/set_fact:/pause: - the action plugin
        # already computed the whole task result on the controller (see
        # ActionResult#final_result's own comment). No module upload/
        # dispatch of any kind, batched or not.
        if final = action_result.final_result
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        substituted_params = action_result.modified_params || substituted_params
      end

      # Same argspec-validation gates as execute_task_once (see there) -
      # batched tasks must fail on a typo'd option exactly like
      # non-batched ones. raw: with no `_raw_params` never reaches them:
      # real's raw action crashes/skips before any module-side validation
      # would run (see the helper's own comment).
      substituted_params = raw_missing_command_params(task, substituted_params)
      if raw_failure = raw_missing_raw_params_failure(task, substituted_params, resolve_task_check_mode(task, vars_context))
        return apply_changed_failed_when(task, raw_failure, vars_context, host) if raw_failure["skipped"]?
        return raw_failure
      end
      if violation = argspec_validation_result(task, substituted_params, vars_context, action_level_only: false, check_mode: resolve_task_check_mode(task, vars_context))
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      become = begin
        resolve_task_become(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end
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

      config_json = build_plugin_config(task, host, substituted_params, remote_vars_context, substituted_become_user, substituted_env, become_flag: become)

      # The batch script runs the plugin binary directly, so it must be on
      # the target before the script is built - pre-upload cannot see
      # modules that only appear inside a runtime include_tasks:.
      # Same transport-failure conversion execute_remote_plugin applies:
      # the returned unreachable result flows through the callers'
      # JSON::Any branch into finish_single_task, which books it exactly
      # like the pre-run unreachable pass does.
      begin
        PluginManager.ensure_uploaded(host, task.module_name, vars_context)
      rescue ex : PluginArchUnsupportedError
        # Same failed-task shape the plugin dispatch itself returns for
        # this (see execute_remote_plugin's typed rescue): one clean
        # failed task with the actionable arch message, never an
        # unhandled crash and never a bogus UNREACHABLE.
        return JSON.parse({"changed" => false, "failed" => true, "msg" => ex.message.to_s}.to_json)
      rescue ex
        raise ex unless SSHManager.connection_level_exception?(ex)
        detail = ex.message.to_s.lines.first?.to_s
        return JSON.parse({
          "changed"     => false,
          "msg"         => SSHUnreachableMsg.unreachable_msg(detail, vars_context, host),
          "stderr"      => detail,
          "unreachable" => true,
        }.to_json)
      end
      step_conn = ConnectionSettings.resolve(host, vars_context)
      plugin_target = PluginManager.remote_plugin_target(task.module_name, become, become_user, step_conn.user, Passwords.become(vars_context, host), substituted_become_flags)

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
      # own, and asking for one would spawn it under a `sudo` that
      # Ansible never runs - and that a minimal host may not even have.
      BatchScript::Step.new(plugin_target, config_json, resolve_task_ignore_errors(task, vars_context),
        PluginManager.simple_plugin_name(task.module_name),
        PluginManager.become_needed?(become, become_user, step_conn.user) ? become_user : nil,
        substituted_params, substituted_become_flags)
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
    # task args failed" rescue) as one clean failed task - Ansible's
    # own "couldn't resolve module/action 'x'" verdict for a templated
    # name that renders to something unknown.
    # ansible-core renders a templated action's module name during task
    # post-validation, so a top-level fact read inside it deprecates with
    # the directive's own VALUE token as Origin - live-verified against
    # 2.21.6: `action: "{{ ansible_pkg_mgr }}"` reports that value's
    # opening quote, and the mapping form the `module:` value (galexrt.ntp,
    # issue #988). Registered as the fiber's templated-param site - the
    # same mechanism a task arg's fact read uses, with the same
    # one-block-per-operation dedupe (two tasks each naming a fact get one
    # block each, a looped action one for all its items).
    private def resolve_templated_action(task : Task, substitutor : VarSubstitutor) : Task
      raw = task.templated_action || return task

      rendered = with_templated_action_param_site(task, raw) { substitutor.substitute(raw).strip }
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
      resolved_task.action_name = raw_name
      resolved_task.params = merged
      # The copy is what every post-resolution display/register decision
      # downstream of execute_task_once must see as the module - the
      # shared original keeps the as-written template text.
      resolved_task.resolved_templated_name = resolved
      resolved_task
    end

    private def with_templated_action_param_site(task : Task, raw : String, & : -> T) : T forall T
      site = task.templated_action_site
      return yield unless site
      key, line, col = site
      origin = task.source_file.try { |path| ErrorBlock.origin_context(path, line, col) }
      VarSubstitutor.set_current_task_param(task.source_file, line, key, raw, origin)
      begin
        yield
      ensure
        VarSubstitutor.pop_current_task_param
      end
    end

    # ansible coerces the templated async:/poll: value with int(), so a
    # templated bool (async: "{{ not ansible_check_mode }}") arrives as
    # int(True)=1 / int(False)=0 rather than an unparseable "True" string
    # - and a 0 async: means synchronous. The substituted text carries
    # Crystal's Bool#to_s capitalization ("True"/"False"), so match it
    # case-insensitively alongside plain integers; poll: 0 (fire and
    # forget) stays a legal 0, only the async: consumer treats 0 as off.
    private def substitute_async_value(text : String) : Int32?
      stripped = text.strip
      case stripped.downcase
      when "true"  then 1
      when "false" then 0
      else              stripped.to_i?
      end
    end

    # Modules real executes WITHOUT its python interpreter machinery:
    # raw/command/shell/script hand their payload straight to the
    # connection's shell, so no interpreter is resolved for them and a
    # missing interpreter cannot fail them (every other module reaching
    # the local dispatch is a python-module run as far as the
    # interpreter question goes).
    NO_INTERPRETER_MODULES = Set{
      "raw", "ansible.builtin.raw", "ansible.legacy.raw",
      "command", "ansible.builtin.command", "ansible.legacy.command",
      "shell", "ansible.builtin.shell", "ansible.legacy.shell",
      "script", "ansible.builtin.script", "ansible.legacy.script",
    }

    # The synthesized result for a local-dispatch module whose resolved
    # interpreter is missing on the controller, or nil when the task
    # would have run (real included). Resolution follows module_common's
    # _get_shebang: the ansible_python_interpreter var wins when defined
    # (an "auto*" value re-enters discovery, i.e. consults the gathered
    # discovered_interpreter_python fact next), otherwise that fact,
    # otherwise real would run discovery through the local connection
    # and succeed - so no interpreter means no failure here. Delegated
    # tasks return nil (see the dispatch-site comment).
    private def local_interpreter_missing_result(task : Task, host : Host, exec_host : Host, vars_context : Hash(String, JSON::Any), substitutor : VarSubstitutor) : JSON::Any?
      return nil unless exec_host == host
      return nil if NO_INTERPRETER_MODULES.includes?(task.module_name)
      return nil if PluginManager.remote_execution?(task.module_name, exec_host, vars_context)
      return nil if PluginManager.controller_only?(task.module_name)

      configured = nil
      if raw = vars_context["ansible_python_interpreter"]?
        begin
          configured = render_task_var_value(raw, vars_context, host.name).as_s?
        rescue UndefinedVariableError
          # An unrenderable interpreter var fails real's module run
          # through its own templating error later, not through this
          # check - leave the task to the ordinary dispatch.
          configured = nil
        end
      end

      interpreter = if configured && !configured.empty? && !configured.starts_with?("auto")
                      configured
                    else
                      vars_context["discovered_interpreter_python"]?.try(&.as_s?)
                    end
      return nil unless interpreter && !interpreter.empty?
      return nil unless FactsGatherer.interpreter_missing?(interpreter)

      # Real's action raises the deserialization AnsibleError when the
      # interpreter's output is not module JSON - the fatal payload
      # below is its exact result_dict (live-captured, issue #374),
      # with the _ansible_* markers driving the [ERROR] block's
      # three-link action chain in ResultDisplay.
      result = JSON.parse({
        "changed"                      => false,
        "failed"                       => true,
        "module_stderr"                => "/bin/sh: 1: #{interpreter}: not found\n",
        "module_stdout"                => "",
        "msg"                          => "The module interpreter '#{interpreter}' was not found.",
        "rc"                           => 127,
        "_ansible_action_level"        => true,
        "_ansible_error_detail"        => "Action failed: The module interpreter '#{interpreter}' was not found.",
        "_ansible_interpreter_missing" => interpreter,
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_MSG_FIRST)
      result
    end

    private def execute_task_once(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      item_label : String? = nil,
      exec_host : Host = host,
      shared : VarSubstitutor? = nil,
      defer_loop_stats : Bool = false,
      loop_item : JSON::Any? = nil,
      loop_index : Int32? = nil,
      defer_when_chain : Bool = false,
    ) : JSON::Any?
      substitutor = shared || VarSubstitutor.new(vars: vars_context, host_name: host.name)

      begin
        return nil unless when_passes?(task, vars_context, host, item_label, shared: substitutor, defer_stats: defer_loop_stats, defer_unavailable_module: true)
      rescue ex : WhenEvaluationError
        # Returning a real `failed: true` result here (not swallowing
        # and returning `false`/nil) lets it flow through the exact same
        # pipeline a normal task failure does: the solo caller passes it
        # to `finish_single_task` (register/notify/display/stats/halt,
        # ignore_errors: and all), and - critically - a LOOPED caller
        # collects it into `finish_looped_task`'s per-item results array,
        # so a looped when: failure correctly aggregates to `failed=1`
        # in the recap (matching Ansible's "One or more items
        # failed"), not `skipped=1` the way silently returning nil here
        # used to.
        #
        # ansible-core 2.19.11 prints the [ERROR] chain block BEFORE
        # the fatal line (see emit_when_error_chain) - here, at catch
        # time, so it precedes whatever the pipeline prints. A looped
        # caller (defer_when_chain) defers instead: every failing item
        # raises through this same rescue, but ansible prints each
        # item's block immediately before THAT item's failed line, in
        # iteration order - finish_looped_task emits it there off the
        # result's (already per-item-origin-decorated) msg. The chain
        # dedups identical repeats only.
        unless defer_when_chain
          emit_when_error_chain(task, ex.message || "", host, loop_item: loop_item, loop_index: loop_index, cause_text: ex.cause_text)
        end
        return when_error_result(ex, task, host, loop_item: loop_item, loop_index: loop_index)
      end

      # A delegated task's CONNECTION is the delegated host's, not the
      # origin's: everything from the connection-plugin check below through
      # the plugin dispatch must resolve against the delegate (see
      # delegated_dispatch_vars). Param templating above and the
      # when:/failed_when: evaluation below keep the ORIGIN's context -
      # ansible templates a delegated task's args against the task's own
      # (origin) vars and books the result on the origin host.
      dispatch_vars = exec_host == host ? vars_context : delegated_dispatch_vars(host, exec_host, vars_context)

      # Ansible resolves the task's effective connection type through
      # its plugin loader right after the when: evaluates and BEFORE the
      # module ever runs, failing the task with "Task failed: the
      # connection plugin 'X' was not found" when nothing resolves -
      # including a case-mismatched spelling ("Local"/"Podman", the
      # loader's name match is case-sensitive) and any FQCN that names no
      # real connection plugin (community.grafana.grafana is a module
      # namespace only). vars_context already carries the merged value
      # (inventory/host vars, or this ONE task's own `connection:`
      # override - see build_vars_context). Previously ANY non-"local"
      # value silently fell back to SSH: an unresolvable connection
      # turned into a bogus UNREACHABLE ("Failed to connect to the host
      # via ssh") instead of Ansible's one clean failed task.
      if (conn_type = dispatch_vars["ansible_connection"]?.try(&.as_s?)) &&
         PluginManager.connection_plugin_not_found?(conn_type)
        return apply_changed_failed_when(task, JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "Task failed: the connection plugin '#{conn_type}' was not found",
        }.to_json), vars_context, host)
      end

      # Same keyword-first ordering as prepare_batch_step. task.become_user
      # itself is never mutated here, since Task is shared/reused across
      # hosts and loop iterations.
      substituted_become_user = begin
        resolve_task_become_user(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end

      # Same keyword-first ordering as prepare_batch_step (issue #465):
      # a templated become: renders before any module arg is finalized.
      if task.become_expr
        begin
          resolve_task_become_flag(task, host, vars_context, substitutor)
        rescue ex : UndefinedVariableError
          return keyword_failure_json(ex, task)
        end
      end

      # Issue #735: same diff:/check_mode: keyword post-validation as
      # prepare_batch_step.
      if error = boolean_keyword_invalid_error(task, vars_context)
        return keyword_failure_json(error, task)
      end

      # The no_log keyword is strictly templated alongside become_user
      # before any task body runs (issue #317): an undefined reference in
      # a templated no_log: fails the task here, where the lenient
      # resolution used to keep it running (and masking) the whole way
      # through.
      if undefined = no_log_keyword_undefined_error(task, vars_context)
        return no_log_keyword_failure_json(task, undefined)
      end

      # ansible 2.19.11 resolves a mapping-form local_action:/action:'s
      # module BEFORE templating the task args: observed live with an
      # undefined variable in the args, the failure is "Cannot resolve
      # '...' to an action or module." (rc=2), not "Finalization of task
      # args ... failed" - the undefined variable never surfaces. A
      # reached task whose mapping module is definitively unresolvable
      # therefore fails HERE, before arg templating. As with the
      # unavailable-module skip below, a role-private library/ source
      # still runs (same python_module_source_for condition), and this
      # failure never registers in reachable_unavailable_modules - it is
      # the task's own rc=2, not the engine-limit exit-4 accounting (a
      # when:-false task skips upstream in when_passes? with no
      # registration either).
      if task.unresolvable_mapping_module? && python_module_source_for(task).nil?
        return unresolvable_mapping_module_failure(task)
      end

      begin
        substitute_block_name_chain(task, substitutor)
        task = resolve_templated_action(task, substitutor)
        substituted_params = expand_templated_args(substitute_task_params(task.params, substitutor, native_containers: task.module_name.ends_with?("set_fact"), module_name: task.module_name, task: task), substitutor, task)
        substituted_env = substitute_task_environment(task, substitutor)
      rescue ex : BlockNameKeywordError
        # Same keyword-level shape as prepare_batch_step's identical
        # rescue above: ansible fails the child at "Error processing
        # keyword 'name'", not "Finalization of task args".
        return block_name_keyword_failure_json(ex, task)
      rescue ex
        # A raised exception during param substitution (e.g. lookup('url',
        # ...) hitting a real HTTP error - see ExpressionEvaluator#
        # fetch_url_lines's own comment) means Ansible's own
        # "finalization of task args failed" hard stop: it fails the
        # ENCLOSING TASK cleanly (one recap entry, playbook continues to
        # whatever's next per normal when:/rescue: semantics), not the
        # whole run. Before this rescue existed, nothing in the call
        # chain up through krikri-playbook.cr's own top-level `run` caught
        # such an exception at all, so it crashed the entire process
        # with an unhandled-exception stack trace instead - found
        # benchmarking buluma.victoriametrics's own `set_fact: _checksums:
        # "{{ lookup('url', ...) }}"` against a 404'd release checksums
        # file (a broken-upstream default, but Ansible still
        # degrades to one clean failed task, not a crash).
        # No "changed" key would match Ansible's pre-2.19 display;
        # 2.19.11 (live-captured) shows {"changed": false, "msg": ...},
        # so the failed result carries changed: false.
        result = finalization_failure_json(ex, task)
        # Stash, don't print: when this runs as a batch group's detour
        # member (execute_batch_group's fingerprint-mismatch path), the
        # call happens during batch-build, before the earlier members'
        # results display - an inline print put the block ahead of the
        # previous task's changed: line (issue #14, pylabs.nginx). The
        # display path prints it under this task's own banner, just before
        # the fatal line; the solo path's display comes through the same
        # flush, at the same relative position the inline print had.
        if ex.is_a?(UndefinedVariableError) && (text = finalization_error_block_text(task, ex, host, vars_context))
          TaskExecutor.stash_finalization_error_block(result, text)
        end
        # Deliberately NOT routed through apply_changed_failed_when:
        # failed_when:/changed_when: govern whether a MODULE RESULT counts
        # as failed/changed, and arg finalization failed before any module
        # ran - Ansible (ansible-core 2.19) still reports
        # `fatal: ... Finalization of task args ... failed` on this task
        # even with `failed_when: false` set (previously the finalization
        # failure was funneled through failed_when: like a runtime result,
        # so `failed_when: false` swallowed it as `ok:` and the play
        # continued to the next task). ignore_errors: still applies
        # downstream (Ansible honors it here: ignored=1, play
        # continues), which this plain failed result preserves.
        return result
      end

      # A reached task-level import_playbook (issue #762) fails here
      # instead of skipping below: ansible-core's module loader RESOLVES
      # the action to the doc-only stub (lib/ansible/modules/
      # import_playbook.py) and the base action plugin's _execute_module
      # dies on its shebang check, raising a controller-side AnsibleError
      # - a per-task failure honoring ignore_errors:, not the graceful
      # skip other unported modules take. Like them it fails only AFTER
      # arg finalization (real resolves the module after the args
      # finalize), and it never registers in reachable_unavailable_
      # modules - the failure is the task's own, not the engine-limit
      # exit-4 accounting.
      if task.unavailable_import_playbook? && python_module_source_for(task).nil?
        return import_playbook_missing_interpreter_failure(task)
      end

      # A genuinely-reached unavailable module whose when: passed and whose
      # arg finalization was clean skips HERE, not inside when_passes? -
      # ansible's order is when: -> arg finalization -> module resolution
      # for a RESOLVABLE module, so an undefined variable in the args had
      # to fail above (see when_passes?'s defer_unavailable_module comment)
      # before this skip could happen; a definitively-unresolvable mapping
      # module is the 2.19.11-observed exception (module resolved before
      # arg templating) handled by the guard above. Same bookkeeping
      # when_passes? would have performed.
      if (unavailable = task.unavailable_module) && python_module_source_for(task).nil?
        # The exit-4 accounting for an unported module registers HERE,
        # after arg finalization succeeded (and only for a module that will
        # NOT run - a role-private library/ source dispatches below and is
        # not "unavailable" in the engine-limit sense): real resolves a
        # task's module only after its args finalize, so a task that failed
        # finalization on an undefined variable never reached the module at
        # all - its failure is the task's own (rc=2), not the engine-limit
        # exit-4 (round 5460184, CiscoUcs.ucs: the looped ucs_timezone
        # tasks carry `hostname: "{{ ucs_hostname }}"` with that var
        # undefined, and the registration used to happen back in
        # when_passes?, before this point). The Set dedups the looped
        # path's per-item registrations.
        reachable_unavailable_modules << unavailable
        # A LOOPED caller (defer_loop_stats) must not print or book-keep
        # here: its "skipping:" line has to print from finish_looped_task in
        # iteration order (executed items and when:-false skips all display
        # there), and the caller's nil detection performs the perform_skip
        # bookkeeping itself with the loop item bound (round 5460184).
        return nil if defer_loop_stats
        perform_skip(task, host, item_label, defer_stats: defer_loop_stats, defer_display: false, item: nil)
        return nil
      end

      # `timeout:` - the task's wall-clock limit (ansible-core's
      # TASK_TIMEOUT alarm around handler.run). Resolved at the same point
      # real's post_validate converts it: after `when:` and arg
      # finalization, but BEFORE the action plugin runs (live-verified vs
      # 2.19.11: a pause: task with an out-of-range or non-convertible
      # timeout fails with NO "Pausing for ..." console line). The
      # deadline then covers the ACTION PLUGIN too - real's alarm wraps
      # all of handler.run (ansible/executor/task_executor.py), not just
      # the module dispatch - and the module dispatch below inherits
      # whatever budget the action stage did not spend. async: tasks
      # keep NO deadline: real's alarm only wraps the fire-and-forget
      # dispatch itself (the handler returns the job id immediately), so
      # the detached job stays governed by `async:` alone.
      task_timeout, timeout_failure = resolve_task_timeout(task, substitutor)
      if timeout_failure
        return timeout_failure
      end
      task_deadline = task_timeout ? Time.instant + task_timeout.seconds : nil

      # Action-only directives (debug/assert/fail/pause/script/... and
      # group_by) are validated by Ansible's ACTION PLUGIN, before any
      # action runs - this pre-action hook handles exactly those; the
      # post-action hook below handles every module-level spec. Placed
      # before the controller-side pseudo-module branches (group_by)
      # so their action-level "Invalid options" check is not preempted.
      if violation = argspec_validation_result(task, substituted_params, vars_context, action_level_only: true, check_mode: resolve_task_check_mode(task, vars_context))
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      if task.module_name == "ansible.builtin.reboot"
        result = execute_reboot(substituted_params, exec_host, dispatch_vars, resolve_task_check_mode(task, dispatch_vars))
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

      warn_groupby_storage(task)
      warn_markup_storage(task)
      substituted_params = resolve_role_relative_src(task, substituted_params)
      # Ansible's copy ACTION plugin rejects src+content together before
      # anything else runs (even before the src file lookup) - live-
      # verified ordering, see ArgspecValidator's module comment.
      if violation = copy_src_content_conflict(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      if violation = copy_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      copied = inline_copy_source_content(task, substituted_params, exec_host, dispatch_vars)
      if copied.is_a?(JSON::Any)
        return apply_changed_failed_when(task, copied, vars_context, host)
      end
      substituted_params = copied
      # Ansible's dest expand crash fires only after the src lookup succeeded
      # (inline_copy_source_content above) - the last of copy.py's
      # non-string-literal crash points, see copy_literal_type_failure.
      if violation = copy_dest_expand_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      # Ansible's unarchive/assemble action plugins crash on non-string
      # literal args at their own controller-side touch points, before
      # the src staging paths could leak the marker into a message or
      # upload path - see unarchive_assemble_literal_type_failure.
      if violation = unarchive_assemble_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end
      staged = stage_unarchive_remote_src(task, substituted_params, exec_host, dispatch_vars)
      if staged.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged, vars_context, host)
      end
      substituted_params = staged
      staged_script = stage_script_src(task, substituted_params, exec_host, dispatch_vars)
      if staged_script.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged_script, vars_context, host)
      end
      substituted_params = staged_script
      staged_assemble = stage_assemble_dir(task, substituted_params, exec_host, dispatch_vars)
      if staged_assemble.is_a?(JSON::Any)
        return apply_changed_failed_when(task, staged_assemble, vars_context, host)
      end
      substituted_params = staged_assemble
      # Ansible's assemble action expands the destination's user path itself
      # after the fragments are staged and before the copy module ever
      # validates anything - so a non-string literal dest crashes the
      # action instead of failing the copy spec. See
      # assemble_dest_expand_failure.
      if violation = assemble_dest_expand_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible's add_host: the groups failure (action stage) and the
      # inventory.add_host name crash (result-processing stage, which
      # aborts the whole run) - see add_host_literal_type_failure.
      if violation = add_host_literal_type_failure(task, substituted_params)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      # Ansible validates the become: keyword before any action plugin runs,
      # so a non-boolean templated become: fails debug: and the other
      # controller-side actions too (issue #143).
      begin
        resolve_task_become(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end

      # The gather_facts action's own `parallel:` conversion runs inside the
      # action plugin, i.e. after the become: keyword check and before any
      # fact module - see gather_facts_parallel_failure.
      if violation = gather_facts_parallel_failure(task, substituted_params, vars_context)
        return apply_changed_failed_when(task, violation, vars_context, host)
      end

      if ActionPluginManager.has_action_plugin?(task.module_name)
        # task_host is the TASK's own host, passed only when delegate_to: is
        # in play (exec_host above is the delegate-resolved endpoint) - see
        # prepare_batch_step's identical call for why. A plain remote task
        # (no delegate_to:) must NOT hit synchronize's dest_is_local branch:
        # that dispatched the module binary onto the target host, where a
        # pull-mode dest: pointing into the controller failed rsync's mkdir
        # (softasap.sa-vpn-softether round 2300304).
        action_result = execute_action_with_deadline(task_deadline) do
          ActionPluginManager.execute_action(
            task.module_name,
            substituted_params,
            vars_context,
            exec_host,
            @inventory,
            task.delegate_to ? host : nil,
            resolve_task_check_mode(task, vars_context),
            task_deadline,
            task.action_name
          )
        end
        # The deadline expired during the action stage itself (real's
        # alarm fires inside handler.run, wherever it happens to be).
        if action_result.nil?
          period = task_timeout
          raise "task timeout expiry without a period" unless period
          return task_timeout_result(period)
        end
        emit_assert_that_deprecations(task, substituted_params, action_result, vars_context)

        unless action_result.success?
          failed = {
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }
          # An ACTION-level failure (a bare AnsibleActionFail raised by
          # the plugin itself) renders without the "Module failed." chain
          # segment - see ActionResult#action_level. A crash_failure's msg
          # is Ansible's own "Task failed: <exception>" wrapper while its
          # [ERROR] block text stays bare - see ActionResult#error_detail.
          failed["_ansible_action_level"] = true if action_result.action_level?
          if detail = action_result.error_detail?
            failed["_ansible_error_detail"] = detail
          end
          if err_origin = action_result.error_origin?
            failed["_ansible_error_origin"] = err_origin
          end
          if undef_origin = undef_chain_result_origin(task, action_result, host)
            failed["_ansible_undef_chain_origin"] = undef_origin
          end
          result_json = JSON.parse(failed.to_json)
          Krikri.mark_failed_key_order(result_json, FAILED_KEY_ORDER_MSG_FIRST)
          return apply_changed_failed_when(task, result_json, vars_context, host)
        end

        bump_hv_generation_for_add_host(task.module_name)

        if final = action_result.final_result
          if timeout_with_console = action_plugin_timeout_result(final, task_timeout)
            return timeout_with_console
          end
          return apply_changed_failed_when(task, final, vars_context, host)
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      # Whatever of the task's `timeout:` budget the action stage (and
      # the controller-side gates above it) already spent: real's alarm
      # is set ONCE before handler.run and keeps counting through the
      # module dispatch, so the dispatch gets the remainder, not the
      # whole budget again.
      dispatch_timeout = remaining_dispatch_timeout(task_deadline)

      # Same override execute_remote_plugin used to apply to the wire
      # payload only (never to vars_context itself, which stays the
      # controller's own view for when:/changed_when:/failed_when:
      # evaluation) - once a plugin is actually running on the remote,
      # its own internal local-vs-remote logic needs to see itself as
      # local. Deciding it *before* serializing is what lets the config
      # be built exactly once here, the way prepare_batch_step already
      # builds it once for the batch path; this used to serialize, parse,
      # then dup and re-serialize the entire variable context.
      # The same become resolution and validation resolve_become used to
      # perform from inside PluginManager, hoisted to the call site so
      # the config String can be handed straight through without being
      # parsed again. Identical defaults (become_user "root" when become:
      # is set but become_user: isn't) and identical error message -
      # and identical to what prepare_batch_step does for the batch path.
      # Resolved BEFORE build_plugin_config so the wire config's own
      # become: field (async:'s job file resolves it back out via
      # resolve_become) carries the same var-aware verdict the dispatch
      # below uses. Hoisted ahead of the module-level argspec check too:
      # the sudo skip decision below needs the resolved become, and the
      # resolution does not depend on the argspec result.
      become = begin
        resolve_task_become(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end
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
      substituted_become_flags = begin
        resolve_task_become_flags(task, host, vars_context, substitutor)
      rescue ex : UndefinedVariableError
        return keyword_failure_json(ex, task)
      end

      # raw: with no `_raw_params` never reaches the aliased shell plugin's
      # argument spec at all - real's raw action crashes/skips before any
      # module-side validation would run (see the helper's own comment).
      substituted_params = raw_missing_command_params(task, substituted_params)
      if raw_failure = raw_missing_raw_params_failure(task, substituted_params, resolve_task_check_mode(task, vars_context))
        # The check-mode skip rides the same pipeline a plugin-produced skip
        # does; the crash escapes before the changed_when/failed_when pass
        # runs in real, so it must bypass it here too.
        return apply_changed_failed_when(task, raw_failure, vars_context, host) if raw_failure["skipped"]?
        return raw_failure
      end

      # Real's raw action hands the command straight to the CONNECTION
      # (_low_level_execute_command), never to the command module, so the
      # module's strip_empty_ends trailing-\r\n rstrip never applies: raw's
      # registered stdout/stderr keep their trailing newline (`raw: echo hi`
      # registers stdout "hi\n"; a failed spawn keeps dash's "...not
      # found\n" - live-verified vs 2.19.11, issue #896). The shell plugin
      # raw is aliased onto defaults that strip to true, so raw's dispatch
      # forces it off for every raw run; the remote pty-merged capture
      # below bypasses that strip on its own either way.
      if RAW_MODULES.includes?(task.action_name || task.module_name)
        substituted_params = substituted_params.dup
        substituted_params["strip_empty_ends"] = "false"
        # Marks the raw dispatch for the shell plugin, whose result builder
        # serves command/shell/raw with one code path: raw.py kept the
        # 2.19 non-zero-rc msg where 2.21's command.py reworded it, and
        # MODULE_ALIASES has already rewritten task.module_name to the
        # shell target by the time the config is built, so the plugin
        # cannot recover the invoked spelling from _module_name. The
        # _ansible_ prefix keeps it out of every validation and register
        # shape the way the other internal args are.
        substituted_params["_ansible_raw_dispatch"] = "1"
      end

      # Data-driven module argument validation against Ansible's own
      # argument specs (see ArgspecValidator) - the same checks the real
      # module's AnsibleModule init runs, controller-side, before the
      # plugin is dispatched (so a typo'd option fails without any file
      # access, exactly like real). Runs after the action-plugin stage:
      # template's Jinja knobs are consumed there, and copy/template's
      # source content is already inline for the failure dump's checksum.
      # Action-level entries were already handled above.
      #
      # Skipped when the local sudo dispatch is about to fail anyway
      # (issue #498): ansible validates a module's own arguments INSIDE
      # the module, i.e. only after the become escalation has succeeded,
      # so on a controller whose sudo needs a password (and none is
      # configured) a task with an unsupported parameter dies as sudo's
      # "Premature end of stream waiting for become success" failure
      # before any argument validation ever runs. The dispatch below then
      # produces that real-shaped failure via
      # PluginManager.become_premature_end_result. The `sudo -n` probe
      # only runs once the cheaper arms have already singled out a local
      # sudo dispatch with no configured become password.
      goes_remote = PluginManager.remote_execution?(task.module_name, exec_host, dispatch_vars)
      controller_only = PluginManager.controller_only?(task.module_name)
      become_password = Passwords.become(dispatch_vars, host)
      sudo_noninteractive = false
      if !goes_remote && !controller_only && become && become_password.nil? &&
         PluginManager.become_needed?(become, become_user, PluginManager.local_username)
        sudo_noninteractive = become_user ? PluginManager.sudo_noninteractive?(become_user) : false
      end
      unless PluginManager.local_become_would_fail?(!(goes_remote || controller_only), become, become_user, become_password, sudo_noninteractive)
        if violation = argspec_validation_result(task, substituted_params, vars_context, action_level_only: false, check_mode: resolve_task_check_mode(task, vars_context))
          return apply_changed_failed_when(task, violation, vars_context, host)
        end
      end

      wire_vars = vars_context
      # A delegated task's module runs under the DELEGATE's interpreter
      # vars in real ansible - that is how `delegate_to: localhost`
      # picks up the implicit localhost's own ansible_python_interpreter
      # (the python ansible itself runs under, issue #1005). Everything
      # else keeps the origin's context (krikri templates a delegated
      # task's params against the origin's vars, and the plugins that
      # read full vars - debug:/assert: - show the origin's).
      if exec_host != host
        wire_vars = vars_context.dup
        INTERPRETER_VAR_KEYS.each do |key|
          if value = dispatch_vars[key]?
            wire_vars[key] = value
          end
        end
      end
      if PluginManager.remote_execution?(task.module_name, exec_host, dispatch_vars)
        wire_vars = dispatch_vars.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      # Remote raw must look like real's `ssh -tt` capture: ONE stream
      # carrying the command's stdout and stderr interleaved in execution
      # order (issue #490). raw_remote_pty_shape cannot recover that
      # order from the shell plugin's two separately captured pipes, so
      # the merge has to happen at the source: this internal param makes
      # plugins/shell.cr wrap the invocation in `{ ...; } 2>&1` (the same
      # group the remote script run uses), leaving the plugin's stderr
      # empty. Local raw keeps the captured streams - no pty exists
      # there. When the plugin could allocate a real target-side pty
      # (PtyCommandRunner) the capture is already the sshd-shaped pty
      # stream - isatty-sensitive programs like apt behave differently on
      # a pty than on a pipe (issue #775) - and the plugin's
      # _krikri_real_pty result marker tells raw_remote_pty_shape to keep
      # that stdout verbatim.
      #
      # __raw_pty_term rides along with the merge marker: real's raw
      # command always sees a TERM (the ssh session's - the client's
      # effective TERM, which sshd installs for the pty session), and
      # terminfo-driven programs colour and size their output from it:
      # dnf emits its \e[1m\e[32m package highlights and abbreviates its
      # table headers ("Arch"/"Repo") only when terminfo resolves, so a
      # TERM-less pty child renders the same run plain-text and
      # wide-columned (issue #820, abn.managed-node-bootstrap's
      # bootstrap raw task). The controller's own TERM is the value real
      # ends up with (the ssh client takes it from there), the same
      # source the become-daemon TERM forwarder (issue #606) already
      # uses; the target's plugin process env carries no usable TERM at
      # all, which is not what real's pty session has.
      if RAW_MODULES.includes?(task.action_name || task.module_name) &&
         PluginManager.remote_execution?("shell", exec_host, dispatch_vars)
        substituted_params = substituted_params.dup
        substituted_params["__raw_pty_merge"] = "1"
        if (term = ENV["TERM"]?) && !term.empty?
          substituted_params["__raw_pty_term"] = term
        end
      end

      config = build_plugin_config(task, exec_host, substituted_params, wire_vars, substituted_become_user, substituted_env, become_flag: become, become_flags: substituted_become_flags)

      # ansible resolves templated async:/poll: per host at execution
      # time, so the parser leaves those as raw text; without resolving
      # them here a task like async: "{{ n }}" silently ran synchronously
      # and never printed the ASYNC POLL/OK lines. The shared Task is
      # never mutated (vars are per host) - a shallow copy carries the
      # resolved values into execute_async only.
      resolved_async = task.async_seconds
      if resolved_async.nil? && (raw_async = task.async_raw)
        resolved_async = substitute_async_value(substitutor.substitute(raw_async))
      end
      resolved_poll = task.poll_seconds
      if resolved_poll.nil? && (raw_poll = task.poll_raw)
        resolved_poll = substitute_async_value(substitutor.substitute(raw_poll))
      end
      if resolved_async && (resolved_async != task.async_seconds || resolved_poll != task.poll_seconds)
        task = task.dup
        task.async_seconds = resolved_async
        task.poll_seconds = resolved_poll
      end

      # Ansible resolves a python module's interpreter from the PLAYED
      # HOST's vars even when the task itself runs on the controller
      # under a `connection: local` override (module_common's
      # _get_shebang consults task_vars regardless of the connection):
      # the ansible_python_interpreter var, or the interpreter the
      # host's own fact gathering discovered
      # (discovered_interpreter_python), is executed by the
      # controller's /bin/sh, and a path that only exists on the remote
      # host dies with rc 127 and an empty module stdout, which real
      # reports as the module-interpreter-not-found action failure
      # (2kloc.trellis-monit's `find:` task, issue #374: the controller
      # has no /usr/bin/python3.10; the Ubuntu 22.04 target discovered
      # it at gather time). Krikri's plugins are native binaries that
      # would run happily through this exact setup, so the case is
      # detected here and shaped like real's deserialization failure.
      # Delegated tasks stay out of scope: the interpreter then comes
      # from the DELEGATE host's vars, which this dispatch context does
      # not carry faithfully.
      if failure = local_interpreter_missing_result(task, host, exec_host, vars_context, substitutor)
        return apply_changed_failed_when(task, failure, vars_context, host)
      end

      # async: 0 must run synchronously like ansible: its task executor
      # coerces async_val with int() (templated bools land as 1/0) and
      # then gates the async path on Python truthiness, where 0 is falsy -
      # e.g. async: "{{ not ansible_check_mode }}" on a real run is plain
      # synchronous execution with a registered result, not a job.
      if (async_secs = task.async_seconds) && async_secs != 0 && !resolve_task_check_mode(task, wire_vars)
        # async: writes this config verbatim to a job file; the detached
        # __async_run process resolves become:/become_user: back out of
        # it via the JSON::Any entry point, exactly as before. Remote
        # hosts take the SSH fire-and-forget path inside execute_async
        # (needs the substitutor/become_user context the local path
        # re-derives itself).
        return apply_changed_failed_when(task, execute_async(task, exec_host, config, dispatch_vars, substitutor, substituted_become_user), vars_context, host)
      end

      # The arbitrary-Python-module runner: an unavailable module with a
      # role-private `library/<name>.py` source dispatches to the
      # py_module plugin with the source embedded (base64), running it
      # on the target with the target's own python3. Reached only after
      # when_passes? let it through (see its own comment), so a python
      # module behind a false when: still skips normally.
      if task.unavailable_module && (py_source = python_module_source_for(task))
        result = execute_python_module(task, py_source, substituted_params, exec_host, dispatch_vars, wire_vars, become, become_user, substituted_become_user, substituted_env, dispatch_timeout, substituted_become_flags)
        if period = marker_task_timeout(result)
          return task_timeout_result(period)
        end
        # ansible-core 2.21's INJECT_INVOCATION default: the module's own
        # _return_formatted (the shim, which every py_module run now
        # uses) already popped `invocation` when the flag was absent from
        # the module args; a module that set kwargs['invocation'] itself
        # still hands one back - shed it here, matching what the
        # controller-side result would carry under the setting's
        # resolution (see InvocationInjection).
        result = InvocationInjection.strip(result) unless InvocationInjection.enabled?(vars_context)
        return apply_changed_failed_when(task, result, vars_context, host)
      end

      result = PluginManager.execute_plugin(
        task.module_name,
        config,
        exec_host,
        dispatch_vars,
        become,
        become_user,
        dispatch_timeout,
        substituted_become_flags
      )

      if period = marker_task_timeout(result)
        return task_timeout_result(period)
      end
      result = shape_raw_result(task, result, substituted_params,
        PluginManager.remote_execution?("shell", exec_host, dispatch_vars),
        exec_host.connection_host)
      result = shape_script_result(task, result)
      result = attach_invocation(task, substituted_params, result, InvocationInjection.enabled?(vars_context))
      apply_changed_failed_when(task, result, vars_context, host)
    end

    # One definition, shared with the batcher's own raw exclusion
    # (TaskBatcher::raw_task?) - raw also aliases to shell, so a second
    # hand-maintained copy here would drift silently.
    RAW_MODULES = TaskBatcher::RAW_MODULES

    # The executable-present half of raw:'s missing-`_raw_params` behavior:
    # real's raw action reads ONLY `_raw_params` and `executable` off the
    # task args and silently ignores every other parameter - `free_form:`
    # (the docs' documented option name), `cmd:` and `argv:` alike - and
    # with `executable:` set even a NO-command-source raw task still RUNS:
    # the empty command `<executable> -c ''` exits 0 and reports plain
    # changed (live-verified vs 2.19.11). krikri executes raw through the
    # shell plugin, whose spec DOES require a command and DOES reject
    # unknown params, so params falling out of real's two reads must be
    # reduced to exactly what the action plugin would forward - with an
    # empty `_raw_params` standing in for real's defaulted-to-empty one.
    # Runs BEFORE raw_missing_raw_params_failure below: this fills the
    # `_raw_params` the crash gate checks, so the gate keeps failing only
    # the executable-less cases real crashes on (issue #765) and never the
    # executable-present ones this helper converts into the empty run
    # (issue #766). Without `executable:` real fails the task
    # controller-side instead (connection.exec_command(None) crashes) -
    # that shape is the crash gate's, not this helper's.
    private def raw_missing_command_params(task : Task, params : Hash(String, String)) : Hash(String, String)
      return params unless RAW_MODULES.includes?(task.action_name || task.module_name)
      return params if task.module_args_string_form?
      return params if params.has_key?("_raw_params")
      return params unless (executable = params["executable"]?) && !executable.empty?
      kept = params.select { |key, _| key == "executable" || key.starts_with?("_ansible_") || key.starts_with?("__") }
      kept["_raw_params"] = ""
      kept
    end

    # raw:'s action plugin reads ONLY `_raw_params`
    # (ansible/plugins/action/raw.py hands `self._task.args.get('_raw_params')`
    # straight to _low_level_execute_command): `free_form:`/`cmd:`/`argv:` are
    # params it never consults, and raw has no Ansible-module side to reject
    # them either (there is no raw.py module - the action plugin talks to the
    # connection directly). A raw task whose finalized args leave
    # `_raw_params` unset therefore hands None into the connection and dies
    # on Python's "'NoneType' object is not iterable" INSIDE the action - the
    # task executor's uncaught-exception wrapper words the result
    # "Task failed: <exception>" (live-verified vs 2.19.11), and failed_when:
    # never applies (the exception escapes _execute_internal before the
    # changed_when/failed_when pass runs, live-verified). krikri aliases raw:
    # onto the shell plugin, whose required_one_of accepts cmd:/argv: and
    # words the empty case "one of the following is required: _raw_params,
    # cmd, argv" - none of which real does. Check mode diverges the same way:
    # real's action plugin returns the bare skip shape BEFORE reading any
    # args, while the aliased module-side spec check fails the task.
    private def raw_missing_raw_params_failure(task : Task, params : Hash(String, String), check_mode : Bool) : JSON::Any?
      return nil unless RAW_MODULES.includes?(task.action_name || task.module_name)
      return nil if params.has_key?("_raw_params")
      # A bare-string raw (`raw: echo hi`) is real's _raw_params shape:
      # krikri stores the same command under `cmd` for the aliased shell
      # plugin, and it must keep running - only the MAPPING form can leave
      # `_raw_params` unset (see Task#module_args_string_form).
      return nil if task.module_args_string_form?
      if check_mode
        return JSON.parse({"skipped" => true, "failed" => false, "changed" => false}.to_json)
      end
      result_json = JSON.parse({
        "changed"               => false,
        "failed"                => true,
        "msg"                   => "Task failed: 'NoneType' object is not iterable",
        "_ansible_action_level" => true,
        "_ansible_error_detail" => "'NoneType' object is not iterable",
      }.to_json)
      Krikri.mark_failed_key_order(result_json, FAILED_KEY_ORDER_MSG_FIRST)
      result_json
    end

    # raw: is aliased to the shell plugin binary, whose result carries
    # command-style keys (cmd/start/end/delta, an empty msg) Ansible's raw
    # action never returns. Ansible's raw result is
    # {rc, stdout, stdout_lines, stderr, stderr_lines, changed, failed}
    # plus msg/exception on a non-zero rc (live-verified 2.19.11).
    # Internal `_ansible_*` keys the failure renderer needs are kept,
    # after the real keys.
    # executable the task names: raw's spawn failure is a LOGIN-SHELL
    # report, not a spawn report (see raw_spawn_failure_shape below).
    private def shape_raw_result(task : Task, result : JSON::Any, substituted_params : Hash(String, String), remote : Bool, addr : String) : JSON::Any
      return result unless RAW_MODULES.includes?(task.action_name || task.module_name)
      hash = result.as_h? || return result
      failed = hash["failed"]?.try(&.as_bool?) || false
      # raw: does not support check mode: Ansible's executor skips it with the
      # bare {skipped, failed, changed} shape.
      if hash["skipped"]?.try(&.as_bool?)
        return JSON.parse({"skipped" => true, "failed" => false, "changed" => false}.to_json)
      end
      # A shell-plugin spawn failure means the task's own `executable:` was
      # missing/inexecutable - real's raw action hands it to the connection's
      # login shell instead and reports what THAT shell printed (the rewrite
      # below). Everything else keeps the aliased-plugin shape untouched.
      if failed && (exe = substituted_params["executable"]?) &&
         (spawn_failure = TaskExecutor.raw_spawn_failure_shape(hash, exe, remote, addr))
        return spawn_failure
      end
      shaped = {} of String => JSON::Any
      %w[rc stdout stdout_lines stderr stderr_lines changed failed].each do |key|
        shaped[key] = hash[key] if hash.has_key?(key)
      end
      shaped["changed"] = JSON::Any.new(true) unless hash.has_key?("changed") && failed
      shaped["failed"] = JSON::Any.new(failed)
      if failed
        %w[msg exception].each { |key| shaped[key] = hash[key] if hash.has_key?(key) }
        # raw is an ACTION plugin in real: its failure renders as
        # "Task failed: Action failed: <msg>", not "Module failed:".
        if msg = hash["msg"]?.try(&.as_s?)
          shaped["_ansible_action_level"] = JSON::Any.new(true)
          shaped["_ansible_error_detail"] = JSON::Any.new("Action failed: #{msg}")
        end
      end
      dropped = %w[cmd start end delta msg exception]
      hash.each do |key, value|
        shaped[key] = value unless shaped.has_key?(key) || dropped.includes?(key)
      end
      # Real's remote raw result is what came off the ssh pty, not the
      # pipes the shell plugin captured (see raw_remote_pty_shape).
      TaskExecutor.raw_remote_pty_shape(shaped, remote, addr)
      JSON::Any.new(shaped)
    end

    # Real ansible runs raw over the connection with a pty (ssh -tt,
    # because raw sends no stdin - issue #490's eendroroy.pyenv capture):
    # the target's stdout and stderr arrive on the SAME pty, merged in
    # execution order with ONLCR having turned every \n into \r\n, and
    # the ssh client's own stderr holds only its mux close notice. Two
    # capture shapes reach this:
    #
    # - The plugin captured the command on a REAL target-side pty
    #   (PtyCommandRunner - needed because a pty changes how
    #   isatty-sensitive programs like apt behave, issue #775). Its
    #   _krikri_real_pty marker says the stdout already IS that pty
    #   stream: nothing to merge or re-translate, and the marker comes
    #   back off the result here. The ssh client's close notice is
    #   synthesized the same way as for the emulated capture.
    # - The pipe emulation (`{ ...; } 2>&1`, ScriptPtyCapture's
    #   pty_merged_command - the fallback for pty-less targets): the
    #   plugin's stdout carries both streams in order but still plain
    #   \n, and ONLCR gets re-applied here. (The stream merge happens at
    #   the source so the plugin's stderr is empty; appending the
    #   (empty) stderr stays harmless and keeps results that reached
    #   this path without the marker shaped.)
    #
    # Local raw has no pty, so it keeps the captured streams untouched.
    # Rewrites the hash in place to keep the shaped result's key order
    # intact.
    def self.raw_remote_pty_shape(hash : Hash(String, JSON::Any), remote : Bool, addr : String) : Nil
      return unless remote
      if hash.delete("_krikri_real_pty").try(&.as_bool?)
        closed = PluginHelpers::ScriptPtyCapture.connection_closed_stderr(addr)
        hash["stderr"] = JSON::Any.new(closed)
        hash["stderr_lines"] = JSON.parse([closed.rstrip("\r\n")].to_json)
        return
      end
      merged = (hash["stdout"]?.try(&.as_s?) || "") + (hash["stderr"]?.try(&.as_s?) || "")
      hash["stdout"] = JSON::Any.new(PluginHelpers::ScriptPtyCapture.pty_stdout(merged))
      hash["stdout_lines"] = JSON.parse(PluginHelpers::AnsibleSplitlines.split(merged).to_json)
      closed = PluginHelpers::ScriptPtyCapture.connection_closed_stderr(addr)
      hash["stderr"] = JSON::Any.new(closed)
      hash["stderr_lines"] = JSON.parse([closed.rstrip("\r\n")].to_json)
    end

    # The shell plugin pre-checks the task's `executable:` locally and
    # reports the raw errno as rc (2 ENOENT, 13 EACCES) with msg "Error
    # executing command." - but real's raw action never spawns the
    # executable itself. It passes it to _low_level_execute_command, which
    # sends `<executable> -c '<cmd>'` through the CONNECTION's own login
    # shell; the missing/inexecutable binary is then reported BY that shell
    # as an ordinary non-zero exit - 127 for ENOENT, 126 for EACCES - which
    # the raw action wraps in the plain failed dict: changed: true, msg
    # "non-zero return code", and none of the spawn report's cmd/exception
    # keys. The wording differs by branch because the shells differ: local
    # runs through /bin/sh (dash: "not found"), remote through the
    # pty-attached ssh login shell - issue #631's capture shows bash's "No
    # such file or directory" there (dash login shells would word it
    # differently; not verified). Returns nil when the hash is not a raw
    # spawn failure, so every other raw path keeps its shape.
    def self.raw_spawn_failure_shape(hash : Hash(String, JSON::Any), executable : String, remote : Bool, addr : String) : JSON::Any?
      return nil unless hash["failed"]?.try(&.as_bool?) &&
                        hash["msg"]?.try(&.as_s?) == "Error executing command."
      local_reason, remote_reason, rc = case hash["rc"]?.try(&.as_i?)
                                        when  2 then {"not found", "No such file or directory", 127}
                                        when 13 then {"Permission denied", "Permission denied", 126}
                                        else         return nil
                                        end
      if remote
        # The remote side's output rides the pty into stdout (ONLCR turns
        # every \n into \r\n), leaving only openssh's own close notice on
        # the ssh client's stderr - the same shapes the script action's
        # pty-attached run produces.
        raw_stdout = "bash: line 1: #{executable}: #{remote_reason}\n"
        stdout = PluginHelpers::ScriptPtyCapture.pty_stdout(raw_stdout)
        stderr = PluginHelpers::ScriptPtyCapture.connection_closed_stderr(addr)
        stderr_lines = [stderr.rstrip("\r\n")]
      else
        raw_stdout = ""
        stdout = ""
        stderr = "/bin/sh: 1: #{executable}: #{local_reason}\n"
        stderr_lines = PluginHelpers::AnsibleSplitlines.split(stderr)
      end
      JSON.parse({
        "rc"                    => rc,
        "stdout"                => stdout,
        "stdout_lines"          => PluginHelpers::AnsibleSplitlines.split(raw_stdout),
        "stderr"                => stderr,
        "stderr_lines"          => stderr_lines,
        "changed"               => true,
        "failed"                => true,
        "msg"                   => "non-zero return code",
        "_ansible_action_level" => true,
        "_ansible_error_detail" => "Action failed: non-zero return code",
      }.to_json)
    end

    SCRIPT_MODULES = {"script", "ansible.builtin.script", "ansible.legacy.script"}

    # yum/dnf belong here alongside script: real's dnf ACTION plugin resolves
    # its backend and, when it cannot, RETURNS a failed dict
    # (`result.update({'failed': True, 'msg': ...})` in dnf.py) instead of
    # raising - so the executor's attempt loop sees an ordinary failed
    # result and retries it like any other failure (live-verified vs
    # 2.19.11). Their `_ansible_action_level`-marked results therefore must
    # NOT take the raised-exception escape from run_until_retries.
    DICT_FAILURE_ACTION_PLUGINS = {"yum", "dnf", "ansible.builtin.yum", "ansible.builtin.dnf", "ansible.legacy.yum", "ansible.legacy.dnf"}

    # script is an ACTION plugin in real: ansible-core's script.py action
    # runs the transferred file itself and returns its OWN result dict (no
    # inner module), so task_executor's maybe_raise_on_result sees that dict
    # before any module-context wrap and raises AnsibleActionCapturedError -
    # a non-zero-exit failure renders "Task failed: Action failed: <msg>",
    # not the "Module failed:" wording a module-reflected result would get
    # (live-verified vs 2.19.11). ADD-only shaping, unlike raw's reshaped
    # contract above: the visible keys and their order must stay untouched,
    # and every visible surface (the fatal dump's clean_for_display strip,
    # register_result's `_ansible_*` reject) already hides `_ansible_*`
    # recursively, so only the failure renderer's collapse lookup reads
    # them. Gated on an `rc` key: only a result the script's own execution
    # produced carries one - the argspec-class plugin failures (mutual
    # exclusion / required_one_of) come from real's validate_argument_spec
    # raise, whose chain krikri renders WITHOUT the "Action failed."
    # segment (that rendering already matches real, and must not change).
    private def shape_script_result(task : Task, result : JSON::Any) : JSON::Any
      return result unless SCRIPT_MODULES.includes?(task.action_name || task.module_name)
      hash = result.as_h? || return result
      return result unless hash["failed"]?.try(&.as_bool?) && hash.has_key?("rc")
      msg = hash["msg"]?.try(&.as_s?)
      return result unless msg && !msg.empty?
      shaped = hash.dup
      shaped["_ansible_action_level"] = JSON::Any.new(true)
      shaped["_ansible_error_detail"] = JSON::Any.new("Action failed: #{msg}")
      JSON::Any.new(shaped)
    end

    # Modules whose registered per-item results (loop `results[]`) carry
    # Ansible's `invocation.module_args` and whose args this engine can
    # reproduce from the argspec table (verified against ansible-core 2.19.11).
    INVOCATION_MODULES = %w[command shell stat file ping slurp lineinfile replace blockinfile find getent get_url]
    # Collection modules with the same verified shape, by FQCN (after alias resolution).
    # x509_certificate_info: path, the two defaults, then content/valid_at null (#367,
    # pacifica.ansible_certinfra's loop over its CA chain).
    INVOCATION_FQCNS = %w[community.crypto.x509_certificate_info]

    private def attach_invocation(task : Task, params : Hash(String, String), result : JSON::Any, inject_invocation : Bool = true) : JSON::Any
      short = task.module_name.sub(/\Aansible\.(builtin|legacy)\./, "")
      fqcn = PlaybookParser::MODULE_ALIASES[task.module_name]? || task.module_name
      spec_name = if INVOCATION_MODULES.includes?(short)
                    "ansible.builtin.#{short}"
                  else
                    # a bare name resolves through the collection search path
                    INVOCATION_FQCNS.find { |name| name == fqcn || name.ends_with?(".#{fqcn}") }
                  end
      hash = result.as_h? || return result
      # A native plugin that mutates its params the way the real module
      # does (community.crypto's in-place valid_at datetime resolution)
      # hands the echoed module_args its resolved values through this
      # private marker - stripped here, before the echo is built, so it
      # never reaches the registered var (register strips _ansible_*
      # anyway) or a -v dump.
      echo_override = hash["_ansible_invocation_module_args"]?.try(&.as_h?)
      if echo_override || hash.has_key?("_ansible_invocation_module_args")
        hash = hash.dup
        hash.delete("_ansible_invocation_module_args")
        result = JSON::Any.new(hash)
      end
      # ansible-core 2.21's INJECT_INVOCATION default is false: module
      # results carry no `invocation` key at all unless the setting is
      # enabled (InvocationInjection's own comment). The gate sits after
      # the echo-marker cleanup and ahead of the echo build, so the OFF
      # case also sheds the invocation a native plugin attached itself
      # (copy's content echo, getent) or a real Python module returned in
      # its own kwargs - the same pop AnsibleModule._return_formatted
      # applies.
      unless inject_invocation
        return InvocationInjection.strip(result)
      end
      return result unless spec_name
      return result if hash.has_key?("invocation")
      # Real's module-crash output (an exception escaping the module -
      # AnsibleModule's top-level handler emits {"failed", "exception"}
      # and nothing else) carries NO invocation at all; a fail_json
      # failure - even one raised inside an active exception - keeps the
      # full shape with invocation (live-verified vs 2.19.11: x509_
      # certificate_info's invalid valid_at spec vs slurp's missing
      # source). krikri spells the crash shape with the controller's
      # "Task failed: Module failed: " msg prefix.
      return result if hash["msg"]?.try(&.as_s?).try(&.starts_with?("Task failed: Module failed: "))
      commandish = short == "command" || short == "shell"
      spec_params = params
      # A free-form command/shell hands its argument to the module as
      # `_raw_params`: the action plugin folds `cmd:` into it before the module
      # ever runs, so `_raw_params` is the SUPPLIED option and `cmd` an
      # unsupplied null. Folding the PARAM (rather than the already-built args)
      # is what puts both in real's slots - supplied args sort alphabetically,
      # so `_raw_params` leads and `cmd` drops back to its declaration-order
      # place among the nulls (zzet.rbenv's loop-registered shell item, #673).
      if commandish && free_form_raw_command?(task) && (raw = params["cmd"]?) && !params.has_key?("_raw_params")
        folded = params.reject { |key, _| key == "cmd" }
        folded["_raw_params"] = raw
        spec_params = folded
      end
      args = ArgspecValidator.invocation_args(spec_name, spec_params) || return result
      if echo_override
        echo_override.each { |key, value| args[key] = value }
      end
      args["_uses_shell"] = JSON::Any.new(true) if short == "shell"
      copy = hash.dup
      invocation = JSON::Any.new({"module_args" => JSON::Any.new(args)} of String => JSON::Any)
      # Real appends `invocation` at the end of the MODULE's own dict, before
      # whatever the action plugin or the controller adds afterwards. For
      # command/shell the module dict ends with `msg` (fail_json's `failed` too
      # on a non-zero rc) and the derived stdout_lines/stderr_lines come after
      # it, so the insertion point is ahead of those - live-verified 2.19.11 on
      # the success, non-zero-rc, creates-skipped and check-skipped item shapes
      # (#673), with `failed` only as the last resort for the commandish shapes
      # that carry neither derived key. For the other modules the only trailing
      # controller key is `failed: false`, which real keeps AFTER the invocation
      # (round 5410000, pacifica.ansible_certinfra's nested stat-result loop;
      # probed single-stat registers carry NO invocation at all, which the
      # non-loop path preserves elsewhere).
      anchor = if commandish
                 {"stdout_lines", "stderr_lines", "failed"}.find { |key| copy.has_key?(key) }
               else
                 copy.has_key?("failed") ? "failed" : nil
               end
      # A fail_json result is {failed, msg} from the module itself with
      # invocation appended right after (live-verified 2.19.11, x509_
      # certificate_info's non-string valid_at, #703): the "failed" anchor
      # above only fits the controller-added `failed: false` of a success.
      if !commandish && copy["failed"]?.try(&.as_bool?) == true && copy.has_key?("msg")
        new_hash = Hash(String, JSON::Any).new
        copy.each do |k, v|
          new_hash[k] = v
          new_hash["invocation"] = invocation if k == "msg"
        end
        return JSON::Any.new(new_hash)
      end
      if anchor
        new_hash = Hash(String, JSON::Any).new
        copy.each do |k, v|
          new_hash["invocation"] = invocation if k == anchor
          new_hash[k] = v
        end
        copy = new_hash
      else
        copy["invocation"] = invocation
      end
      JSON::Any.new(copy)
    end

    # The batch transports' shared entry to attach_invocation: the step
    # carries its fully-substituted params, and a step whose params are
    # unknown (older construction sites, a plugin the argspec table can't
    # reproduce) keeps its result untouched - the same no-args no-attach
    # rule attach_invocation itself applies.
    private def attach_batch_step_invocation(task : Task, step : BatchScript::Step, result : JSON::Any, inject_invocation : Bool) : JSON::Any
      return result unless (params = step.params)
      attach_invocation(task, params, result, inject_invocation)
    end

    # A whole-single-span `{{ expr }}` module/action arg whose structured
    # value is a BIGINT_SENTINEL_PREFIX-marked wide int re-marks the
    # substituted text with the sentinel, so PythonModuleRunner#typed_value
    # keeps it intact and the payload serialization (unquote_bigint_json)
    # hands the module/plugin a real Python int the way Ansible passes its
    # own (issue #695). The substituted wire text is bare digits -
    # indistinguishable from a LITERAL wide-digit string param, which
    # ansible-core keeps a str - so provenance comes from re-evaluating
    # the span STRUCTURALLY, the same seam substitute_task_params' None
    # and "[]" checks use: only a span whose structured value is a marked
    # string whose digits equal the rendered text re-marks. Side-effecting
    # spans (a lookup-carrying variable value) never re-evaluate - they
    # keep the plain digits text.
    private def bigint_typed_param_text(task : Task, key : String, substituted : String,
                                        vars : Hash(String, JSON::Any)) : String
      stripped = substituted.strip
      raw = task.params[key]?
      # A quoted literal ("5", "true", "null") stays a str in ansible-core,
      # but typed_value re-infers int/bool/None from the bare text. A value
      # with no template syntax and unchanged by substitution has no
      # rendered-variable provenance, so ship it as a native JSON string.
      if raw && raw == substituted && !raw.includes?("{{") && !raw.includes?("{%") &&
         !raw.starts_with?(Krikri::NON_STRING_PARAM_PREFIX) &&
         (stripped.in?("true", "True", "false", "False", "None", "null") || stripped.to_i64?)
        return Krikri::NON_STRING_PARAM_PREFIX + substituted.to_json
      end
      # A templated arg only keeps a non-str type when the template is a
      # single `{{ expr }}` span whose value is itself an int/bool/None;
      # a str-valued variable ("5") or a multi-span/mixed template renders
      # to a str in ansible-core.
      if raw && (raw.includes?("{{") || raw.includes?("{%")) &&
         !raw.starts_with?(Krikri::NON_STRING_PARAM_PREFIX) &&
         (stripped.in?("true", "True", "false", "False", "None", "null") || stripped.to_i64?)
        if !VarSubstitutor.single_top_level_span?(raw.strip)
          return Krikri::NON_STRING_PARAM_PREFIX + substituted.to_json
        elsif !Krikri.probe_has_side_effecting_call?(raw)
          rendered = begin
            VariableSubstitutor::ExpressionEvaluator.new(vars)
              .evaluate_structured(raw.strip[2..-3].strip)
          rescue
            nil
          end
          if rendered && rendered.raw.is_a?(String)
            return Krikri::NON_STRING_PARAM_PREFIX + substituted.to_json
          end
        end
      end
      return substituted unless stripped.matches?(/\A-?(0|[1-9]\d*)\z/) && stripped.to_i64?.nil?
      return substituted unless raw && VarSubstitutor.single_top_level_span?(raw.strip)
      return substituted if Krikri.probe_has_side_effecting_call?(raw)
      structured = begin
        VariableSubstitutor::ExpressionEvaluator.new(vars)
          .evaluate_structured(raw.strip[2..-3].strip)
      rescue
        nil
      end
      return substituted unless structured && (digits = Krikri.bigint_digits(structured)) &&
                                digits == stripped
      structured.as_s
    end

    # Dispatches an unavailable-module task that has a role-private
    # `library/<name>.py` source through the py_module plugin. The
    # source travels embedded in the plugin config (base64) so the
    # normal upload-and-execute transport works unchanged for remote
    # hosts; the module's argument dict mirrors Ansible's typed
    # JSON args for new-style modules (the params the parser already
    # JSON-encoded come back as real arrays/dicts for the module).
    private def execute_python_module(task : Task, source_path : String, substituted_params : Hash(String, String), exec_host : Host, vars_context : Hash(String, JSON::Any), wire_vars : Hash(String, JSON::Any), become : Bool, become_user : String?, substituted_become_user : String?, substituted_env : Hash(String, String)? = nil, task_timeout : Int64? = nil, become_flags : String? = nil) : JSON::Any
      module_name = PythonModuleRunner.short_name(task.unavailable_module || task.module_name)
      source_text = File.read(source_path)
      # Ansible's modularizer rewrites the legacy boilerplate marker
      # into the import that pulls AnsibleModule in BEFORE style
      # detection, so the marker-bearing module ships as new-style
      # (JSON stdin args, bundled/shimmed basic.py) like any other -
      # without this the raw source ran with AnsibleModule undefined
      # (kunik.deploy-metadata's deployment_facts, issue #543).
      source_text = PythonModuleRunner.modularize(source_text)
      new_style = PythonModuleRunner.new_style?(source_text)

      # See PythonModuleRunner.missing_interpreter_line? -
      # Ansible's own "module (name) is missing interpreter line"
      # guard, which a shebangless old-style module fixture failed on
      # the real side while this engine ran it and succeeded.
      # Ansible resolves a role's action_plugins/<name>.py BEFORE the
      # library/<name> file, which roles ship only as a placeholder
      # (gzm55.local_ssh_known_hosts): the CONTROLLER-side plugin runs
      # with self._play_context carrying the connection's resolved
      # remote_addr/port, and its returned dict IS the task result -
      # register: sees the play context fields the plugin echoes and
      # the plugin's own changed/failed verdicts (issue #519; the
      # search-path rationale lives with action_plugin_source_for).
      action_plugin = action_plugin_source_for(task)
      if action_plugin
        # The typed-arg convention PythonModuleRunner.build_module_args
        # already established: a parser-marked non-string literal decodes
        # to its native JSON value, a whole-value container template back
        # into a real container, everything else stays a string.
        args = Hash(String, JSON::Any).new
        substituted_params.each do |key, value|
          next if key.in?("check_mode", "diff_mode", "_verbosity", "_environment")
          # The typed-arg convention PythonModuleRunner.build_module_args
          # already established: a parser-marked non-string literal decodes
          # to its native JSON value, a comma-joined list with marked
          # members back into a real array (issue #696 - a list arg with a
          # templated element otherwise ships the sentinel text to the
          # module), a whole-value container template back into a real
          # container, everything else stays a string.
          typed_text = bigint_typed_param_text(task, key, value, vars_context)
          args[key] = Krikri.non_string_scalar(value) || Krikri.non_string_scalar(typed_text) ||
                      PythonModuleRunner.typed_member_list(typed_text) ||
                      PythonModuleRunner.typed_value(typed_text)
        end
        # The effective connection the executor already resolved into the
        # magic var (inventory value, or this task's own connection:
        # override) - the same local-vs-ssh verdict every dispatch site
        # applies; play_context.remote_user mirrors ansible_user the same
        # way build_vars_context fills it.
        connection = vars_context["ansible_connection"]?.try(&.as_s?) ||
                     (PluginManager.local_connection?(exec_host, vars_context) ? "local" : "ssh")
        remote_user = vars_context["ansible_user"]?.try(&.as_s?) || exec_host.user
        # play_context.port is var-driven only: the ansible_port var when
        # one is in scope, otherwise None - even over ssh (ansible's ssh
        # connection leaves the option unset and ssh resolves the port
        # itself; live-verified both directions vs ansible-playbook
        # 2.19.11). NOT the executor's own Host#port: the implicit
        # localhost defaults that to 22 for transport dispatch, which
        # would leak a port ansible's play_context never carries.
        port = vars_context["ansible_port"]?.try(&.as_i?) ||
               vars_context["ansible_ssh_port"]?.try(&.as_i?)
        # A plugin's self._execute_module('uri', ...) must run the named
        # module on THIS task's target through the engine's own dispatch -
        # the host, connection, become and check-mode the task already
        # resolved - and hand the module's result dict back to the plugin,
        # because for these roles the inner module's result IS the task
        # result (agaffney.synology_dsm's Login fails with the uri module's
        # own message, live-verified vs 2.19.11, issue #399).
        dispatcher = ->(inner_module : String, inner_args : Hash(String, JSON::Any)) : JSON::Any {
          inner_params = Hash(String, String).new
          inner_args.each do |key, value|
            # A bigint-marked string arg the plugin passes through to a
            # native inner module demotes to its bare digits - the text
            # every native plugin's param wire has always carried for a
            # wide int (the marked form is the action-args convention
            # only, unquoted at PythonActionRunner's own payload
            # serialization).
            inner_text = value.as_s?
            inner_params[key] = inner_text && (digits = Krikri.bigint_digits(inner_text)) ? digits : (inner_text || value.to_json)
          end
          inner_task = Task.new(task.name, inner_module)
          inner_config = build_plugin_config(inner_task, exec_host, inner_params, wire_vars,
            substituted_become_user, substituted_env, become_flag: become)
          PluginManager.execute_plugin(inner_module, inner_config, exec_host, vars_context,
            become, become_user, task_timeout, become_flags)
        }
        begin
          result = PythonActionRunner.run_action(action_plugin, module_name, args, connection,
            exec_host.connection_host, port, remote_user, become, become_user,
            resolve_task_check_mode(task, wire_vars), vars_context, dispatcher)
          # Ansible's task executor backfills `failed` (and `changed`) onto
          # every action-plugin result before it is registered, APPENDED
          # after the plugin's own keys - a dispatched plugin's dict carries
          # neither unless it sets them (live-verified vs 2.19.11:
          # `{big, v}` registers as {big, v, failed, changed}, issue #697).
          # The module path gets the same backfill from
          # PluginManager.normalize_module_result, which this branch bypasses.
          if (result_hash = result.as_h?) && !result_hash.has_key?("failed")
            result_hash["failed"] = JSON::Any.new(false)
            result_hash["changed"] = JSON::Any.new(false) unless result_hash.has_key?("changed")
          end
          # Ansible's task executor classifies EVERY dict the action layer
          # returns (AnsibleActionCapturedError.maybe_raise_on_result on
          # _execute's result): a failed dict WITHOUT an exception summary is
          # an ACTION-level failure - the "Action failed." chain, not
          # "Module failed." (wcm_io_devops.conga_facts returns
          # {"failed": true, "msg": "parameter conga_environment is required"}
          # after catching its own AnsibleOptionsError, issue #658,
          # live-verified vs 2.19.11) - and a missing 'changed' key becomes
          # false, the same "set the changed property if it was missing" step
          # task_executor._execute applies to every result.
          if (shaped = result.as_h?) && shaped["failed"]?.try(&.as_bool?) == true &&
             shaped["exception"]?.nil?
            shaped["changed"] = JSON::Any.new(false) unless shaped["changed"]?
            if msg = shaped["msg"]?.try(&.as_s?)
              shaped["_ansible_error_detail"] = JSON::Any.new("Action failed: #{msg}")
            end
            shaped["_ansible_action_level"] = JSON::Any.new(true)
            result = JSON::Any.new(shaped)
          end
          return result
        rescue PythonActionRunner::ActionUnavailableError
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "role-local Python action plugin (#{action_plugin}) is not supported by krikri",
          }.to_json)
        rescue ex : PythonActionRunner::ActionError
          if detail = ex.detail
            # The plugin raised AnsibleError itself: ansible's task
            # executor makes that the task's own failure - the fatal
            # msg carries the "Task failed: " prefix while the [ERROR]
            # block shows the bare text in the plain action-level chain
            # with no "Module failed." middle segment (live-verified
            # vs 2.19.11 on amtega.check_platform, issue #411).
            return JSON.parse({
              "changed"               => false,
              "failed"                => true,
              "msg"                   => "Task failed: #{detail}",
              "_ansible_error_detail" => detail,
              "_ansible_action_level" => true,
            }.to_json)
          end
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => ex.message.to_s,
          }.to_json)
        end
      end

      if PythonModuleRunner.missing_interpreter_line?(source_text, new_style)
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "module (#{module_name}) is missing interpreter line",
        }.to_json)
      end

      check_mode = resolve_task_check_mode(task, wire_vars)

      py_params = substituted_params.dup
      py_params["module_name"] = module_name
      py_params["module_source"] = Base64.strict_encode(source_text)
      py_params["new_style"] = new_style.to_s
      py_params["_ansible_check_mode"] = check_mode.to_s
      if new_style
        # Each param rides through bigint_typed_param_text first: a
        # whole-span `{{ big_var }}` arg re-marks to the sentinel so
        # typed_value keeps it and the module_args JSON unquotes it into
        # a real Python int (see that helper's comment).
        typed_params = Hash(String, String).new
        substituted_params.each do |key, value|
          typed_params[key] = bigint_typed_param_text(task, key, value, vars_context)
        end
        py_params["module_args"] = PythonModuleRunner.build_module_args(typed_params, check_mode, module_name)
      else
        py_params["kv_argv"] = PythonModuleRunner.build_kv_argv(substituted_params).to_json
      end
      # The INJECT_INVOCATION resolution rides to the py_module plugin as
      # its own param, NOT inside module_args: the plugin adds the flag
      # to the args itself (on the shim path, which since #915 is every
      # new-style run), and the controller strips `invocation` off the
      # result when the setting is off.
      py_params["_ansible_inject_invocation"] = InvocationInjection.enabled?(vars_context).to_s

      # A role shipping its OWN custom module_utils packages (e.g.
      # linux-system-roles.storage's the Ansible module beside its
      # library/blivet.py) gets that tree bundled into the plugin config
      # the same way the module source itself travels (base64, relative
      # path -> content) - the plugin stages it under
      # the Ansible module on the target so the module's `from
      # ansible.module_utils.<role_pkg>...` import resolves, mirroring
      # Ansible's AnsiballZ bundling of the role's own
      # module_utils/. A role with NO module_utils/ directory - the
      # common case - sends no extra payload at all.
      module_utils_files = PythonModuleRunner.collect_module_utils_files(task.role_path, @playbook_dir)
      unless module_utils_files.empty?
        py_params["module_utils_files"] = module_utils_files
          .to_a.map { |rel, path| {rel, Base64.strict_encode(File.read(path))} }
          .to_h.to_json
      end

      # build_plugin_config takes the effective become_user this caller
      # already carries (the var-aware resolve_task_become_user result -
      # the normal plugin path and the batch path pass the same value);
      # the dispatch below uses the fully-resolved become/become_user.

      # `become`/`become_user` here are the caller's already-resolved
      # values (resolve_task_become, with the play-level become:
      # cascade and the "root" become_user default both applied) - NOT
      # task.become?, which is only the task's OWN explicit become: key
      # and is false whenever a role relies on the PLAY's `become: true`
      # to cascade down (the common shape, since repeating become: true
      # on every task would be redundant). Using task.become? directly
      # here silently dispatched every python-module task unprivileged
      # whenever it inherited become from its play instead of setting
      # its own - found via newrelic.newrelic-infra's own library/
      # merge_yaml.py writing to a become-required system path
      # (/etc/newrelic-infra.yml) under the play's own `become: true`:
      # "Merge YAML failed due to OS error Permission denied (13)",
      # confirmed live against a real host with root/passwordless-sudo
      # already proven to work for every OTHER plugin dispatch in the
      # same play.
      config = build_plugin_config(task, exec_host, py_params, wire_vars, substituted_become_user, substituted_env, become_flag: become)

      # The DISPATCH decision gets the controller's own unflipped
      # vars_context, mirroring the normal plugin dispatch above - NOT
      # wire_vars, whose `ansible_connection=local` override exists only
      # for the plugin's own internal local-vs-remote logic once it has
      # already landed on the remote (the config JSON above carries it
      # for exactly that purpose). execute_plugin re-runs
      # remote_execution? against the vars it is handed, so handing it
      # wire_vars made every remote role-private python module execute
      # LOCALLY ON THE CONTROLLER instead of on the target: on a
      # controller without passwordless sudo the task failed outright
      # with "sudo: a password is required" (reproduced live against a
      # fresh Atlantic.net host); with one it would run the module as
      # root on the wrong machine entirely. This asymmetry (and not any
      # privilege gap inside the python subprocess) is the actual
      # newrelic.newrelic-infra merge_yaml "OS error Permission denied
      # (13)" root cause the round-79 investigation kept missing: the
      # pre-0.9.900 dispatch ran the module unprivileged on the
      # controller, whose labros account cannot write /etc/.
      PluginManager.execute_plugin(
        "ansible.builtin.py_module",
        config,
        exec_host,
        vars_context,
        become,
        become_user,
        task_timeout
      )
    end

    # A name krikri has not ported is only "unavailable" when NOTHING
    # that can run it resolves - a role-private `library/*.py` source or
    # a role-private `action_plugins/*.py` plugin. Ansible resolves a
    # bare task name against the loaded roles' (and the playbook's) own
    # action_plugins/ and RUNS that plugin: amtega.check_platform's
    # `_check_platform:` is implemented solely by
    # action_plugins/_check_platform.py with no `library/` placeholder at
    # all (issue #411 - ansible ran the plugin, which failed the task
    # with its own "<dist> distribution is not supported" AnsibleError,
    # rc=2, while this engine - finding no source - treated the name as
    # an unavailable module and exit-4s'd). So an unavailable_module with
    # an action plugin beside it is dispatched like the gzm55
    # library+action pair, not skipped; this feeds the skip and
    # registration guards in when_passes?, the run loop, the loop paths
    # and the handler paths alike.
    private def python_module_source_for(task : Task) : String?
      unavailable = task.unavailable_module || return nil
      PythonModuleRunner.find_source(
        PythonModuleRunner.short_name(unavailable),
        task.role_path,
        @playbook_dir
      ) || action_plugin_source_for(task)
    end

    # The runtime counterpart of collection_index.local_action_plugin?:
    # the resolving role's own action_plugins/ wins; a plugin that lives
    # only in a META DEPENDENCY role's action_plugins/ resolves through
    # the loaded-role registry (ansible's add_all_plugin_dirs puts every
    # loaded role's action_plugins/ on the search path in load order);
    # then the playbook's own action_plugins/ dir, and finally Ansible's
    # configured action dirs (search-order-last there, issue #793).
    private def action_plugin_source_for(task : Task) : String?
      module_name = PythonModuleRunner.short_name(task.unavailable_module || task.module_name)
      if (rp = task.role_path) && !rp.empty?
        own = File.join(rp, "action_plugins", "#{module_name}.py")
        return own if File.file?(own)
      end
      if found_root = PythonFilterRunner.loaded_role_roots("action_plugins")
           .find { |candidate| File.file?(File.join(candidate, "#{module_name}.py")) }
        return File.join(found_root, "#{module_name}.py")
      end
      unless @playbook_dir.empty?
        pb_plugin = File.join(@playbook_dir, "action_plugins", "#{module_name}.py")
        return pb_plugin if File.file?(pb_plugin)
      end
      PythonFilterRunner.configured_roots("action", "ANSIBLE_ACTION_PLUGINS").each do |root|
        configured = File.join(root, "#{module_name}.py")
        return configured if File.file?(configured)
      end
      nil
    end

    # async:/poll: - runs the module as a detached background OS process
    # (spawned via a hidden `__async_run` re-invocation of this same
    # binary, not a Fiber, so the job survives even if the poll loop or
    # the whole playbook run finishes first - closer to how Ansible's
    # background job outlives the control connection). Local connections
    # use that path; REMOTE connections (round 189: mrlesmithjr.
    # change-hostname's own `shutdown -r now` + `async: 1`/`poll: 0`
    # reboot idiom) previously failed outright ("async: is only supported
    # for local connections"), so the host never rebooted while
    # Ansible's fire-and-forget ran it. Remote async now mirrors
    # Ansible's ~/.ansible_async model: the plugin binary is uploaded,
    # then nohup-launched detached on the target with its stdout (the
    # module's own JSON result) collected into ~/.ansible_async/<jid>
    # via an atomic tmp+mv, and poll:ed by cat-ing that file over SSH.
    # Ansible's TaskExecutor collects every deprecation emitted while the
    # task ran into its DeferredWarningContext and puts the collected list
    # on the result as `deprecations` (executor/task_executor.py's
    # result.update(deprecations=...)) - live-verified vs 2.19.11 via
    # register on a failing community.mysql.mysql_info task. For a
    # redirected community.mysql module that is one entry per task
    # occurrence (the console [DEPRECATION WARNING] line, emitted at
    # task-load time by parse_tasks, dedups separately). A result where
    # no module ever ran keeps nothing, mirroring the guards
    # ResultDisplay.consume_pending_module_deprecations already
    # established for the same class of question: module-side skip,
    # unreachable, connection failure, uncaught crash.
    private def attach_module_redirect_deprecations(task : Task, result : JSON::Any) : JSON::Any
      entry = PlaybookParser.redirect_deprecation_result_entry(task.module_name) || return result
      hash = result.as_h? || return result
      return result if hash.has_key?("deprecations")
      return result if hash["skipped"]?.try(&.as_bool?)
      return result if hash["unreachable"]?.try(&.as_bool?)
      return result if hash["_connection_failure"]?.try(&.as_bool?)
      # The load-time module deprecation bypasses the crash wrapper: real
      # attaches the `deprecations` entry even when the module dies with an
      # uncaught exception (live-verified vs 2.19.11: apt_repository's
      # permission-denied fail_json and mysql_info's connect failure both
      # carry the entry), unlike the module-side `_ansible_core_deprecations`
      # removed-param deprecations the wrapper drops on a crash.
      hash["deprecations"] = JSON::Any.new([entry] of JSON::Any)
      JSON::Any.new(hash)
    end

    # A {{ }}-wrapped changed_when:/failed_when:'s render-phase unknown
    # filter: carries the already-worded "Syntax error in template: ..."
    # text (see substitute_conditional_rendering_errors) so the shared
    # conditional rescue can store it verbatim instead of re-wrapping it
    # with the unbraced form's "Syntax error in expression:" wording.
    class ChangedFailedWhenRenderSyntaxError < Exception
    end

    # The {{ }}-wrapped form of a changed_when:/failed_when: compiles its
    # filter names during the RENDER (VarSubstitutor#substitute), before
    # the unbraced expression form's own compile gate inside
    # ConditionalEvaluator ever runs - and real words the two failure
    # classes differently (issue #871, Wtower.python-latest's
    # `failed_when: "{{ ... | version_compare(...) }}"` stores
    # "Syntax error in template: No filter named 'version_compare'."
    # in failed_when_result, live-verified vs 2.19, where the unbraced
    # form's compile keeps the "Syntax error in expression:" wording).
    # The same split the when: paths already make (when_passes?'s
    # braced-render rescue) - tagging the render-phase raise lets the
    # shared rescue word each phase like real does.
    private def substitute_conditional_rendering_errors(substitutor : VarSubstitutor, clause : String) : String
      begin
        substitutor.substitute(clause)
      rescue e : VariableSubstitutor::FilterEngine::FilterFailureError
        # A filter that RAN and raised is a runtime failure, not a
        # template syntax error: real stores the plugin wrapper as-is, or
        # the conditional-evaluation wording for a bare runtime failure
        # (first/last on an empty sequence) - live-verified vs 2.21.6 for
        # both, braced form.
        message = e.message.to_s
        raise ChangedFailedWhenRenderSyntaxError.new(
          message.starts_with?("The filter plugin '") ? message : "Error while evaluating conditional: #{message}"
        )
      rescue e : VariableSubstitutor::FilterEngine::UnknownFilterError
        raise ChangedFailedWhenRenderSyntaxError.new("Syntax error in template: #{e.message}")
      end
    end

    # The *_when_result text for a changed_when:/failed_when: evaluation
    # that RAISED. ansible-core 2.19's strict conditional-type error
    # ("Conditional result (...) was derived from value of type 'int'.
    # Conditionals must have a boolean result.") is raised at the CHECK
    # step, outside task_executor.py's `except AnsibleError` conditional-
    # evaluation trap: its stored text carries NO "Error while evaluating
    # conditional: " prefix (issue #262 - jgkim.atom's
    # `failed_when: return_value.rc` stored the prefixed shape, real the
    # bare lineage-decorated one) and gets the same decoration when:
    # already owns. Every other raise shape keeps the prefixed trap
    # wording - including the other ConditionalBooleanError variants
    # (e.g. the Omit scalar), which the issue's observed check-step
    # wording never covers.
    private def changed_failed_when_error_text(task : Task, key : String, raw : String?, host : Host, exc : Exception) : String
      message = exc.message || ""
      # A braced form's render-phase unknown filter arrives pre-worded
      # ("Syntax error in template: ...", substitute_conditional_rendering
      # _errors) - stored verbatim, like the when:-braced path's wording.
      if exc.is_a?(ChangedFailedWhenRenderSyntaxError)
        return message
      end
      # An unknown filter/test (`search` is a TEST, not a filter - issue
      # #533) is a Jinja COMPILE-time syntax error for ansible: the
      # template parse fails before any conditional evaluation begins,
      # so it escapes the `except AnsibleError` conditional-evaluation
      # trap and stores the bare "Syntax error in expression: ..." shape
      # the template engine itself reports, not the prefixed trap wording.
      #
      # A filter PLUGIN's runtime failure (mandatory's "Mandatory variable
      # 'x' not defined.", indent's operand TypeError) is stored with its
      # own wrapper, no conditional-evaluation prefix (live-verified vs
      # 2.21.6).
      return message if exc.is_a?(Krikri::FilterPluginError) && message.starts_with?("The filter plugin '")
      # A filter that RAN and raised is the runtime class instead
      # (FilterFailureError subclasses UnknownFilterError): its plugin
      # wrapper, or the conditional-evaluation wording for a bare runtime
      # failure - live-verified vs 2.21.6 for both (a raising
      # `changed_when` stores "The filter plugin '...' failed: ...").
      if exc.is_a?(VariableSubstitutor::FilterEngine::FilterFailureError)
        return message.starts_with?("The filter plugin '") ? message : "Error while evaluating conditional: #{message}"
      end
      if exc.is_a?(VariableSubstitutor::FilterEngine::UnknownFilterError)
        return "Syntax error in expression: #{message}"
      end
      unless exc.is_a?(ConditionalEvaluator::ConditionalBooleanError) && message.starts_with?("Conditional result (")
        return "Error while evaluating conditional: #{message}"
      end
      # A reference to the task's OWN register is the one runtime value
      # the lineage lookup can't classify here: the register is merged
      # into this clause's evaluation context but is not applied into
      # the origin-tracked layers until after the result finalizes, so
      # the bare-reference branch of decorate_conditional_value_origin
      # would find no origin and leave the message undecorated. Real
      # treats registered-result lineage as runtime and labels the
      # clause's own value token (bare self-register dict shape
      # live-verified vs 2.19.11). Compound forms reach the same clause
      # token through the decorate path's compound branch by
      # construction, so only the bare identifier needs pinning here.
      if (reg = task.register) && !reg.empty? && raw.try(&.strip) == reg
        return message unless (tok = when_token_position(task, key, raw))
        return with_origin_clause(message, "'#{tok[0]}:#{tok[1]}:#{tok[2]}'")
      end
      decorate_conditional_value_origin(task, message, host, operand: raw, clause_key: key, clause_raw: raw)
    end

    # ansible-core 2.21 labels a RAISING changed_when:/failed_when: with the
    # clause that raised, and renders its own three-part [ERROR] block
    # (live-captured vs 2.21.6):
    #
    #   [ERROR]: Task failed: Action failed: A 'changed_when' expression
    #            failed: <detail>
    #   Task failed: Action failed.
    #   Origin: <task name line>
    #   <<< caused by >>>
    #   A 'changed_when' expression failed: <detail>
    #   Origin: <clause value token>
    #
    # A module that had ALREADY failed keeps its own registered msg and
    # shows "Module failed" in the block instead, and real moves that
    # result's traceback placeholder into `<clause>_when_suppressed_exception`
    # (live-verified: a /bin/false task with a raising failed_when
    # registers the module's own msg plus
    # failed_when_suppressed_exception: "(traceback unavailable)").
    private def record_conditional_clause_failure(hash : Hash(String, JSON::Any), task : Task, clause_key : String, raw : String?, host : Host, module_failed : Bool, detail : String) : Nil
      segment = module_failed ? "Module" : "Action"
      if module_failed
        hash["#{clause_key}_suppressed_exception"] = hash.delete("exception") || JSON::Any.new("(traceback unavailable)")
      else
        # A module that returned its OWN non-empty msg keeps it (real only
        # replaces an absent/empty one - live-verified vs 2.21.6:
        # `debug: msg=hello` behind a raising changed_when keeps "hello"
        # while a command result, whose msg is empty on success, gets the
        # clause chain).
        existing = hash["msg"]?.try(&.as_s?)
        if existing.nil? || existing.empty?
          hash["msg"] = JSON::Any.new(conditional_clause_failure_text(clause_key, segment, detail))
        end
      end
      emit_conditional_clause_error_block(task, clause_key, raw, segment, detail)
      # The block above is the whole display for this failure - keep
      # ResultDisplay's generic "Action failed."/"Module failed." chain
      # from printing a second, unlabelled one.
      hash["_ansible_conditional_clause_emitted"] = JSON::Any.new(true)
    end

    # Runs *block* with the clause's own value position registered as the
    # fiber's current templated-param site, so a deprecation raised while
    # the clause resolves names (the top-level fact alias read) carries
    # the clause value's Origin the way ansible-core's points at it
    # (live-verified 2.21.6: `changed_when: ansible_os_family == 'x'`
    # reports the value token's column).
    private def with_conditional_param_site(task : Task, key : String, raw : String, & : -> T) : T forall T
      VarSubstitutor.set_current_task_param(task.source_file, task.source_line, key, raw)
      begin
        yield
      ensure
        VarSubstitutor.pop_current_task_param
      end
    end

    private def apply_changed_failed_when(task : Task, result : JSON::Any, vars_context : Hash(String, JSON::Any), host : Host) : JSON::Any
      # assert:'s non-bool that: failure rides its raw item text for the
      # fatal msg's lineage clause - inert for every other result shape.
      result = decorate_assert_that_origin(task, result, host)
      # A templated action's resolved module name only exists on the
      # shallow copy resolve_templated_action made inside execute_task_once,
      # but the display runs later against the shared original task (whose
      # module_name is still the raw `{{ }}` text). Stash it as a private
      # key so the display path can prefer it - the same `_ansible_*`
      # keys register strips, so a registered var never carries it.
      if (resolved = task.resolved_templated_name) && (hash = result.as_h?) && !hash.has_key?("_ansible_templated_module_name")
        hash["_ansible_templated_module_name"] = JSON::Any.new(resolved)
        result = JSON.parse(hash.to_json)
      end
      result = attach_module_redirect_deprecations(task, result)
      changed_when = task.changed_when
      failed_when = task.failed_when
      return result unless changed_when || failed_when

      # A `_connection_failure` result (PluginManager's own marker for
      # "no module ever ran to produce a real result" - a become
      # failure, a crashed/missing plugin binary, an SSH-level nonzero
      # exit) has no module JSON for failed_when:/changed_when: to
      # reinterpret in the first place. Ansible's own equivalent
      # (a become/connection failure - e.g. "Premature end of stream
      # waiting for become success") is unignorable by failed_when: -
      # verified live against ansible-core 2.19.4: a `delegate_to:
      # localhost` task needing a sudo password it doesn't have aborts
      # the whole play as `fatal:`, even with `failed_when: false` set,
      # while this engine previously let failed_when: false suppress it
      # and continue. Found via buluma.checkmk_agent's own "Download
      # check_mk_agent installer (deb)" task (`delegate_to: localhost,
      # failed_when: false`, inheriting the play's `become: true`).
      return result if result.as_h?.try(&.["_connection_failure"]?.try(&.as_bool?))

      # A GENUINELY-skipped result (a module returning `skipped: true` -
      # check-mode skip markers, module-side conditional skips) never
      # gets changed_when:/failed_when: evaluated - ansible-core 2.19.4's
      # own guard is `if 'skipped' not in result:` (executor/task_
      # executor.py, the comment reads "if we didn't skip this task, use
      # the helpers to evaluate the changed/failed_when properties").
      # Note this does NOT cover the command/shell `creates:`/`removes:`
      # skip: that result carries no `skipped` key there (it's an
      # ordinary ok result with the full module shape, rc: 0 included -
      # see the plugins' own skip branches), so its changed_when: IS
      # evaluated, exactly as in Ansible.
      return result if result.as_h?.try(&.["skipped"]?.try(&.as_bool?))

      eval_context = vars_context
      if (register_name = task.register) && !register_name.empty?
        eval_context = vars_context.dup
        eval_context[register_name] = with_command_lines_augmented(result)
      end

      # set_fact:'s own result carries the facts it just set under
      # "ansible_facts" (see SetFactActionPlugin), applied into the real
      # vars_context by the caller only AFTER this returns - but
      # Ansible evaluates changed_when:/failed_when: against the task's
      # OWN result, which for set_fact already has those facts merged in.
      # Found via smlloyd.authselect (RHEL-family round 60487): `set_fact:
      # {authselect_current_profile: ...}` with a `changed_when:` that
      # references `authselect_current_profile` right back - Ansible
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

        # raise_undefined: true - ansible-core 2.19 raises while
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
        # task_executor.py's `except AnsibleError` tail (shared note
        # for both clauses): a changed_when:/failed_when: evaluation
        # that RAISES sets failed=True and records the error text -
        # with Ansible's own "Error while evaluating conditional: "
        # prefix - in changed_when_result/failed_when_result, and never
        # touches the module's own msg. The one observed exception is
        # the strict conditional-type wording, stored bare and
        # lineage-decorated instead (changed_failed_when_error_text,
        # issue #262). This used to overwrite msg with
        # the evaluation error, so an argspec-violation result
        # (unsupported parameter) with a broken changed_when: reported
        # "object of type 'dict' has no attribute 'stat'" as its msg
        # where real kept "Unsupported parameters for (...) module: ..."
        # and carried the evaluation error in changed_when_result
        # (live-verified vs 2.19.11 with stat's removed get_md5, round
        # 5220000). UnknownFilterError joins the same rescue (jasonheecs.
        # digitalocean's `changed_when: not python_check.stdout |
        # search('/bin/python')` - `search` is a real-Ansible TEST, not
        # a filter, so Ansible fails the task with "No filter named
        # 'search'.") - previously only the two conditional errors were
        # caught here and the unknown-filter raise escaped all the way
        # out of #run, crashing the whole binary with a stack trace.
        # condname is the clause being evaluated when the error raised
        # ('changed' first, then 'failed').
        # On a result the module did NOT already fail, a RAISING
        # changed_when: finalizes like failed_when:'s failure does - real
        # 2.19.11 routes it through AnsibleActionCapturedError, so the
        # msgless result gets "Task failed: Action failed: Unknown error."
        # (live-verified with file state=absent + a changed_when on
        # result.diff). A result already failed by the module was
        # normalized with the module's own class ("Module failed.") before
        # changed_when: ever ran, and must keep that shape.
        module_failed = hash["failed"]?.try(&.as_bool?) == true
        begin
          if changed_when
            maybe_conditional_delimiters_deprecation(task, changed_when, "changed_when", eval_context)
            changed_when_verdict = with_conditional_param_site(task, "changed_when", changed_when) do
              ConditionalEvaluator.evaluate(substitute_conditional_rendering_errors(substitutor, changed_when), eval_context, strict: true, raise_undefined: true)
            end
            hash["changed"] = JSON::Any.new(changed_when_verdict)
            # TaskExecutor: result['changed_when_result'] = <verdict>
            # whenever changed_when: is set - 2.21's UnifiedTaskResult
            # exports the field on the success path too, so a registered
            # (and thus dumped) result carries it (live-verified vs 2.21.6:
            # a raw task with `changed_when: False` registers
            # changed,changed_when_result,failed,...). The loop AGGREGATE
            # never gets it - only each item result does.
            hash["changed_when_result"] = JSON::Any.new(changed_when_verdict)
          end
        rescue e : ConditionalEvaluator::ConditionalBooleanError | ConditionalEvaluator::UndefinedVariableError | Krikri::FilterPluginError | Krikri::TestPluginError | VariableSubstitutor::FilterEngine::UnknownFilterError | ChangedFailedWhenRenderSyntaxError
          hash["failed"] = JSON::Any.new(true)
          detail = changed_failed_when_error_text(task, "changed_when", changed_when, host, e)
          hash["changed_when_result"] = JSON::Any.new(detail)
          record_conditional_clause_failure(hash, task, "changed_when", changed_when, host, module_failed, detail)
        end

        begin
          if failed_when
            maybe_conditional_delimiters_deprecation(task, failed_when, "failed_when", eval_context)
            failed_when_result = with_conditional_param_site(task, "failed_when", failed_when) do
              ConditionalEvaluator.evaluate(substitute_conditional_rendering_errors(substitutor, failed_when), eval_context, strict: true, raise_undefined: true)
            end
            hash["failed"] = JSON::Any.new(failed_when_result)
            # TaskExecutor: result['failed_when_result'] = <verdict> whenever failed_when: is set
            hash["failed_when_result"] = JSON::Any.new(failed_when_result)
            # a module failure that failed_when: overrides to "not failed" keeps its
            # traceback marker under the suppressed-exception key. 2.21
            # exports that field for EVERY suppressed module failure -
            # including a fail_json result that never carried an
            # `exception` key (live-verified vs 2.21.6: a suppressed `fail:`
            # register reads changed,failed,msg,failed_when_result,
            # failed_when_suppressed_exception) - so synthesize the same
            # placeholder the real failure path uses when there is nothing
            # to move.
            if !failed_when_result && module_failed
              suppressed = hash.delete("exception")
              hash["failed_when_suppressed_exception"] = suppressed || JSON::Any.new("(traceback unavailable)")
            end
            # A failed_when:-failed result with NO msg key finalizes through
            # AnsibleActionCapturedError.normalize_result_exception, whose
            # message defaults to "Unknown error." - only an EMPTY msg keeps
            # the bare "Action failed." block (live-verified vs 2.19.11). The
            # markers route the display through the generic action-level
            # chain, the same shape include_vars' own action failure uses.
            if failed_when_result && !hash.has_key?("msg")
              hash["msg"] = JSON::Any.new("Task failed: Action failed: Unknown error.")
              hash["_ansible_action_level"] = JSON::Any.new(true)
              hash["_ansible_error_detail"] = JSON::Any.new("Action failed: Unknown error.")
            end
          end
        rescue e : ConditionalEvaluator::ConditionalBooleanError | ConditionalEvaluator::UndefinedVariableError | Krikri::FilterPluginError | Krikri::TestPluginError | VariableSubstitutor::FilterEngine::UnknownFilterError | ChangedFailedWhenRenderSyntaxError
          hash["failed"] = JSON::Any.new(true)
          detail = changed_failed_when_error_text(task, "failed_when", failed_when, host, e)
          hash["failed_when_result"] = JSON::Any.new(detail)
          record_conditional_clause_failure(hash, task, "failed_when", failed_when, host, module_failed, detail)
        end
      end

      JSON::Any.new(hash)
    end

    # Register / notify / display / update stats for a (non-looped) task result.
    # fact_host is where a set_fact:/fact-gathering module's ansible_facts
    # attach - normally `host` itself, but the delegate_to:/delegate_facts:
    # combination redirects it to the delegate target instead (Ansible's own documented meaning); register:/display/stats always
    # stay attributed to `host` regardless.
    # Whether *task* on *host* should drop into the debugger, and the
    # loop that does. Returns the (possibly re-run) result.
    # Marks `host` as halted (no further tasks in this play run for it)
    # when `failed` and the task didn't opt out via ignore_errors:.
    #
    # The task's effective `timeout:` limit in seconds, or nil when there
    # is none (keyword absent, or 0 - ansible-core's TASK_TIMEOUT default).
    # Parse-time inheritance (task > block > roles:-entry > play) has
    # already folded the outer levels into Task#timeout; a templated
    # value (Task#timeout_expr) renders per host here. The second tuple
    # element is a pre-built failed-task result for a value that could
    # not be resolved to an integer (Ansible's post_validate conversion
    # error) or falls outside the alarm's 0..100000000 range - checked
    # by the caller BEFORE the failure is returned instead of a dispatch.
    private def resolve_task_timeout(task : Task, substitutor : VarSubstitutor) : {Int64?, JSON::Any?}
      if expr = task.timeout_expr
        rendered = substitutor.substitute(expr)
        if period = rendered.strip.to_i64?
          return validate_task_timeout(period)
        end
        return {nil, task_timeout_conversion_failure(task, rendered)}
      end
      validate_task_timeout(task.timeout)
    end

    private def validate_task_timeout(period : Int64?) : {Int64?, JSON::Any?}
      return {nil, nil} unless period
      return {nil, task_timeout_invalid_result(period)} if period < 0 || period > 100_000_000
      {period == 0 ? nil : period, nil}
    end

    # Whatever of the task's `timeout:` budget is left for the module
    # dispatch: the deadline was started BEFORE the action stage (real's
    # alarm is set once around all of handler.run, and the action plugin
    # - pause's sleep, synchronize's rsync - runs under it), so the
    # dispatch inherits the remainder. nil when the task carries no
    # timeout. Bounded below at 1s, mirroring
    # PluginManager.remaining_exec_timeout's own convention for an
    # already-exhausted budget.
    private def remaining_dispatch_timeout(task_deadline : Time::Instant?) : Int64?
      return nil unless task_deadline
      left = (task_deadline - Time.instant).total_seconds
      left < 1 ? 1_i64 : left.ceil.to_i64
    end

    # Runs the action-plugin dispatch under the task's `timeout:`
    # deadline - real's alarm covers the action plugin too
    # (ansible/executor/task_executor.py wraps handler.run, which
    # includes the action stage). The plugin runs in its own fiber; when
    # the deadline expires first, nil is returned (the caller produces
    # real's task-timeout failure) and the abandoned fiber is left to
    # finish harmlessly in the background - real's SIGALRM likewise only
    # unwinds the controller, leaving the action's child processes
    # running. pause: is the exception: it is deadline-aware itself (see
    # PauseActionPlugin) so its "Pausing for ..." console lines - which
    # real writes just before the alarm fires - survive on the timed-out
    # result, and it always beats this guard's own expiry.
    private def execute_action_with_deadline(task_deadline : Time::Instant?, &block : -> ActionResult) : ActionResult?
      return block.call unless task_deadline
      channel = Channel(ActionResult).new(1)
      spawn do
        begin
          channel.send(block.call)
        rescue
          # The task already returned its timeout result; a late failure
          # in the abandoned plugin fiber is discarded.
        end
      end
      left = (task_deadline - Time.instant).total_seconds
      select
      when result = channel.receive then result
      when timeout(left.seconds) then nil
      end
    end

    # A final action-plugin result that carries the `_task_timeout`
    # marker (PauseActionPlugin's own deadline kill, its console lines
    # aboard): converted to real's task-timeout failure shape while
    # keeping `_ansible_pause_console`, so the lines still print before
    # the [ERROR] block exactly like real's action plugin writing them
    # itself just before the alarm fired.
    private def action_plugin_timeout_result(final : JSON::Any, task_timeout : Int64?) : JSON::Any?
      return nil unless task_timeout
      return nil unless final.as_h?.try(&.has_key?("_task_timeout"))
      result = task_timeout_result(task_timeout, final.as_h["_ansible_pause_console"]?)
      # Marks the kill as ACTION-STAGE (the alarm fired inside the action
      # plugin, not the module dispatch) - ResultDisplay renders that
      # distinction as real's two-segment [ERROR] block.
      result.as_h["_ansible_action_stage_timeout"] = JSON::Any.new(true)
      result
    end

    # The failed task result ansible-core produces when a task outlives
    # its `timeout:` (TaskTimeoutError's ContributesToTaskResult
    # contribution, live-captured from 2.19.11):
    #   {"changed": false, "msg": "Task failed: Timed out after N
    #    second(s).", "timedout": {"frame": ..., "period": N}}
    # Deliberately NOT routed through apply_changed_failed_when: the
    # alarm raises inside handler.run, before failed_when:/changed_when:
    # are ever evaluated, so those keywords cannot reinterpret a run
    # that never produced a result (ignore_errors:/rescue: still apply
    # downstream, which this plain failed result preserves).
    # *console_lines* (an `_ansible_pause_console` array handed over from
    # a deadline-killed PauseActionPlugin) rides along so the display
    # prints the plugin's own console lines before the [ERROR] block,
    # exactly like real's action plugin writing them just before the
    # alarm fired.
    private def task_timeout_result(period : Int64, console_lines : JSON::Any? = nil) : JSON::Any
      result = JSON.parse({
        "changed"  => false,
        "failed"   => true,
        "msg"      => "Task failed: Timed out after #{period} second(s).",
        "timedout" => {
          "frame"  => "Configure `DISPLAY_TRACEBACK` to see a traceback on timeout errors.",
          "period" => period,
        },
      }.to_json)
      result.as_h["_ansible_pause_console"] = console_lines if console_lines
      # Registered order pinned to real's (TaskTimeoutError's
      # result_contribution dict leads the merged registered result):
      # timedout, failed, exception, msg, changed.
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_TIMEOUT)
      result
    end

    # A `timeout:` outside the alarm's supported range fails the task
    # with Ansible's own ValueError wording (live-captured from
    # 2.19.11: `timeout: -5` fails with "Task failed: Timeout -5 is
    # invalid, it must be between 0 and 100000000.") - and with NO
    # `timedout` key, since no alarm ever ran.
    private def task_timeout_invalid_result(value : Int64) : JSON::Any
      result = JSON.parse({
        "changed" => false,
        "failed"  => true,
        "msg"     => "Task failed: Timeout #{value} is invalid, it must be between 0 and 100000000.",
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_MSG_FIRST)
      result
    end

    # A templated `timeout:` that did not resolve to an integer is
    # Ansible's post_validate conversion failure ("Error processing
    # keyword 'timeout': The value 'X' could not be converted to
    # 'int'."). The fatal msg is Ansible's exact collapsed brief; the
    # [ERROR] chain is a best-effort approximation of real's three-link
    # one (real points its innermost link at the source VARIABLE's own
    # definition site, which would need per-value origin tracking this
    # engine does not have) - the middle link carries the timeout:
    # VALUE's own source position, exactly as real's does.
    private def task_timeout_conversion_failure(task : Task, rendered : String) : JSON::Any
      value_repr = "'" + rendered.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'") + "'"
      conversion = "The value #{value_repr} could not be converted to 'int'."
      brief = "Task failed: Error processing keyword 'timeout': #{conversion}"
      result = JSON.parse({
        "changed"                     => false,
        "failed"                      => true,
        "msg"                         => brief,
        "_ansible_timeout_conversion" => JSON.parse({
          "conversion" => conversion,
          "origin"     => timeout_keyword_value_origin(task),
        }.to_json),
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_MSG_FIRST)
      result
    end

    # The `timeout:` VALUE's own column (the first non-space character
    # after the key's colon), same best-effort source scan
    # task_param_value_origin uses - real's middle chain link points
    # there, not at the key.
    private def timeout_keyword_value_origin(task : Task) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)
      lines = File.read_lines(path)
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        at = line.index("timeout:")
        next unless at
        next unless line[0...at].strip.empty?
        col = at + "timeout:".size
        while col < line.size && line[col] == ' '
          col += 1
        end
        return ErrorBlock.origin_context(path, idx + 1, col + 1)
      end
      nil
    end

    # Reads the `_task_timeout` marker a deadline-killed dispatch returns.
    private def marker_task_timeout(result : JSON::Any) : Int64?
      result.as_h?.try(&.["_task_timeout"]?.try(&.as_i64?))
    end

    # A failed `run_once:` task halts every OTHER host in the play too
    # (ansible-core's _process_pending_results: a failed run_once
    # result calls iterator.mark_host_failed(h) for every host in the
    # play except unreachable ones, so no host proceeds into later
    # tasks). Only the host that actually executed the task flows through
    # the normal display/stats path above - the others get no failed=
    # counter and no fatal line of their own, they simply stop (verified
    # against ansible-playbook 2.19.11: a run_once ansible.builtin.
    # fail in a 3-host play recaps failed=1 and no host reaches the next
    # task's banner).
    # force_halt skips the ignore_errors: check - for a dynamic
    # include_role:'s role-resolution failure, which Ansible halts
    # on unconditionally (live-verified vs 2.19.11: `failed=1 ignored=0`
    # even with ignore_errors: true on the include task).
    # *new_failure:* false when re-booking the halt a block's body/
    # rescue failure already earned (execute_block/execute_block_multi's
    # own end) - its @chain_pending_failures classification belongs to
    # that original failure, not to this moment, so it must survive the
    # temporary un-halt the rescue:/always: sections needed.
    private def halt_if_failed(task : Task, host : Host, failed : Bool, result : JSON::Any? = nil, force_halt : Bool = false, new_failure : Bool = true) : Nil
      return unless failed && (force_halt || !resolve_task_ignore_errors(task, host: host))

      @failed_task_info[host.name] = {task, result} if result
      book_failure_halt(host, new_failure)
      return unless task.run_once?

      @hosts.each do |other|
        next if other.name == host.name
        next if @halted_hosts.includes?(other.name)
        next if @unreachable_hosts.includes?(other.name)
        book_failure_halt(other, new_failure)
      end
    end

    # Book a task failure's halt and classify it for abort_play?'s
    # max_fail_percentage: count: a failure that left a rescue:/always:
    # chain running is recorded in @chain_pending_failures (and never
    # counts), anything else counts and clears a stale classification
    # from an earlier, since-recovered failure episode.
    private def book_failure_halt(host : Host, new_failure : Bool = true) : Nil
      @halted_hosts.add(host.name)
      return unless new_failure

      if @block_chain_depth > 0
        @chain_pending_failures.add(host.name)
      else
        @chain_pending_failures.delete(host.name)
      end
    end

    # While the yielded section runs, the host's block still owes a
    # rescue:/always: chain, so failures booking halts inside it don't
    # count toward max_fail_percentage: (see @chain_pending_failures) -
    # matching Ansible, where such a failure lands the host in
    # RESCUE/ALWAYS instead of being booked into _tqm._failed_hosts.
    private def with_pending_chain(&)
      @block_chain_depth += 1
      begin
        yield
      ensure
        @block_chain_depth -= 1
      end
    end

    # Execute a task once per loop item, aggregating the per-item results
    # into a single registered variable (`{"changed": .., "results": [...]}`),
    # matching Ansible's shape for looped, registered tasks.
    private def inherit_when_condition(condition : String, tasks : Array(Task)?) : Nil
      inherit_when_condition(condition, nil, tasks)
    end

    private def inherit_when_condition(condition : String, condition_list : Array(String)?, tasks : Array(Task)?) : Nil
      return unless tasks

      tasks.each do |nested_task|
        existing = nested_task.when_condition

        if existing.nil? || existing.empty?
          nested_task.when_condition = condition
          nested_task.when_condition_list = condition_list if condition_list
        elsif existing != condition && !existing.starts_with?("(#{condition}) and ")
          nested_task.when_condition = "(#{condition}) and (#{existing})"
          if condition_list
            nested_task.when_condition_list = condition_list + (nested_task.when_condition_list || [existing])
          end
        end

        # A nested block: is transparent - push through to its own
        # children, same as print_skipped_tasks does for the skip path.
        if nested_task.block?
          inherit_when_condition(condition, condition_list, nested_task.block_tasks)
          inherit_when_condition(condition, condition_list, nested_task.rescue_tasks)
          inherit_when_condition(condition, condition_list, nested_task.always_tasks)
        end
      end
    end

    # `block_task`'s `when:` reaches its children the way Ansible's parent
    # chain does: as a merged condition string AND as the block's own
    # clauses, which the children - including the files their dynamic
    # includes load - evaluate individually (see
    # Task#block_inherited_when).
    private def inherit_block_when(block_task : Task, tasks : Array(Task)?) : Nil
      return unless tasks
      return if tasks.empty?
      condition = block_task.when_condition
      return unless condition

      chain = block_when_chain(block_task)
      return if chain.empty?
      inherited = BlockInheritedWhen.new(
        chain.size == 1 ? chain.first : chain.map { |clause| "(#{clause})" }.join(" and "),
        chain,
        block_when_origins(block_task))
      inherit_when_condition(condition, block_task.when_condition_list, tasks)
      tasks.each { |nested_task| nested_task.block_inherited_when = inherited }
    end

    # The clauses `block_task` itself contributes to its children: its own
    # when: clauses, with any chain the block inherited from an ENCLOSING
    # block stripped back off (inherit_when_condition prepends that chain
    # to when_condition_list, so the tail is the block's own).
    private def block_when_chain(block_task : Task) : Array(String)
      own = block_task.when_condition_list ||
            (block_task.when_condition ? [block_task.when_condition.as(String)] : [] of String)
      outer = block_task.block_inherited_when.try(&.conditions)
      return own unless outer && own.size > outer.size
      own[outer.size..]
    end

    private def block_when_origins(block_task : Task) : Hash(String, {String, Int32, Int32})?
      outer = block_task.block_inherited_when.try(&.origins)
      own = conditional_clause_origins(block_task, "when", block_when_chain(block_task))
      return outer || own unless outer && own
      merged = outer.dup
      own.each { |clause, origin| merged[clause] = origin }
      merged
    end

    # The ambient Play an include directive's loaded tasks are parsed
    # against: the include statement's own become/become_user (what this
    # engine has always propagated to the tasks it loads) with the
    # statement's `apply:` mapping overriding, the way Ansible's implicit
    # apply-Block (task_include.py's build_parent_block) would give its
    # children block-level defaults that the task's own keyword beats.
    private def include_inherited_play(task : Task) : Play
      inherited = Play.new("", "")
      if apply_become = task.include_apply_become
        inherited.become = apply_become
      else
        inherited.become = task.become?
      end
      inherited.become_user = task.include_apply_become_user || task.become_user
      inherited.become_flags = task.include_apply_become_flags || task.become_flags
      inherited.check_mode = task.include_apply_check_mode
      inherited.check_mode_expr = task.include_apply_check_mode_expr
      inherited
    end

    # The per-task half of that merge, applied once the include has
    # actually loaded its tasks: the apply-Block's vars (only as a default -
    # an included task's own vars: still wins) and its when: (prepended to
    # each task's own, the same short-circuit order inherit_when_condition
    # already gives a real block's children). become/become_user/check_mode
    # never reach this method - the parser resolved them through
    # #include_inherited_play while the tasks were being parsed.
    private def apply_include_attrs(task : Task, loaded : Array(Task)) : Nil
      if apply_vars = task.include_apply_vars
        loaded.each do |loaded_task|
          apply_vars.each { |key, value| loaded_task.vars[key] = value unless loaded_task.vars.has_key?(key) }
        end
      end
      if apply_when = task.include_apply_when
        inherit_when_condition(apply_when, task.include_apply_when_list, loaded)
      end
      # The enclosing BLOCK's `when:` rides Ansible's parent chain into the
      # tasks a dynamic include loads, so each of them evaluates it too -
      # which is where real prints the deprecation a block-level fact read
      # raises (issue #990). A STATIC import is excluded: the parser already
      # merged its own when: into the loaded tasks at parse time.
      unless task.is_static_import?
        if inherited = task.block_inherited_when
          inherit_when_condition(inherited.condition, inherited.conditions, loaded)
          loaded.each { |loaded_task| loaded_task.block_inherited_when = inherited }
        end
      end
      # Ansible's module_defaults context is a RUNTIME stack: an
      # include_tasks: inside a defaults-carrying block applies those
      # defaults to the tasks it loads, though no parse-time pass ever
      # saw them (agaffney.synology_dsm's wrapper block hands its
      # synology_dsm_api_request base_url to login.yml, issue #399).
      unless task.effective_module_defaults.empty?
        PlaybookParser.apply_module_defaults(loaded, task.effective_module_defaults)
      end
    end

    # Expands a block:-wrapped handlers/main.yml entry into its own
    # block_tasks, so a task's `notify:` naming the INNER task's name
    # (not the outer block's) resolves correctly - Ansible flattens
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
    # Verified live against ansible-core 2.19.4 and 2.21.3 (both
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
    # Re-applies --tags/--skip-tags/never selection to a task list that
    # only exists at RUN time - the file or role an
    # include_tasks:/include_role: just loaded. The play's own list was
    # filtered once before the executor started; Ansible applies the
    # identical rules to every dynamically loaded task too (a `never`
    # task in an included file stays out, `--skip-tags` reaches it, and
    # `tagged`/`untagged` see its tags), with the include statement's
    # inherited context (play/block/roles:-entry/import tags - NOT its
    # own declared tags: real Ansible gives dynamic includes' children
    # only the parent-chain tags) plus its `apply: {tags:}` mapping as
    # the inherited set. Loading the included file also stamps each
    # loaded statement's own context, so a nested include inside it
    # propagates correctly on the next pass.
    #
    # A HANDLER's load (statement.tag_exempt?) skips selection entirely:
    # Ansible never tag-filters handlers - a `never`-tagged handler runs
    # when notified under a plain invocation, and tasks a handler
    # include_tasks:'s keep running under `--tags zzz` (live-verified vs
    # 2.19.11). The exemption is stamped onto everything that load pulled
    # in so a nested include below a handler stays exempt as well.
    private def filter_runtime_loaded(loaded : Array(Task), statement : Task) : Array(Task)
      if statement.tag_exempt?
        mark_tag_exempt(loaded)
        return loaded
      end

      inherited = statement.inherited_tags.dup
      if apply_tags = statement.include_apply_tags
        inherited.concat(apply_tags)
      end
      Krikri::TagFilter.apply(loaded, Krikri::RunOptions.run_tags, Krikri::RunOptions.skip_tags, inherited, keep_static_imports: true)
    end

    # Recursive tag-exemption stamp - see filter_runtime_loaded.
    private def mark_tag_exempt(tasks : Array(Task)) : Nil
      tasks.each do |task|
        next if task.tag_exempt?
        task.tag_exempt = true
        mark_tag_exempt(task.block_tasks || [] of Task)
        mark_tag_exempt(task.rescue_tasks || [] of Task)
        mark_tag_exempt(task.always_tasks || [] of Task)
      end
    end

    private def run_task_list(tasks : Array(Task), host : Host) : Nil
      ensure_grouped(tasks)

      tasks.each do |nested_task|
        break if @halted_hosts.includes?(host.name)
        # end_role: skip the ended role's remaining tasks silently (no
        # banner - execute_task's own check would skip the body but the
        # banner below would still print).
        next if role_ended_for_host?(nested_task, host)
        # Same silent-pre-banner treatment for the per-host dependency
        # dedup (issue #320): a re-occurrence whose identity the host
        # already ran produces nothing at all, banner included - and a
        # fully-skipped task's empty banner is exactly the shape this
        # next line exists to avoid.
        next if role_dep_dedup_skipped_for_host?(nested_task, host)

        # A nested block: is transparent - like Ansible, a named
        # block gets no "TASK [...]" banner of its own, only its members
        # do (execute_task already dispatches straight to execute_block,
        # which prints its own children's banners via this same
        # run_task_list). include_tasks: is NOT transparent -
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

        Krikri::OutputBanner.banner("#{task_banner_kind} [#{task_role_prefix(nested_task)}#{render_task_name_for_display(nested_task, host)}]")
        print_task_path(nested_task)
        execute_task(nested_task, host)
      end
    end

    # "TASK" or, while a HANDLER's own include_tasks: subtree runs,
    # "RUNNING HANDLER" - real's callback prints every banner inside a
    # handler flush as "RUNNING HANDLER [...]", including tasks pulled
    # in by the include and anything THEY in turn include (live-verified
    # vs 2.19.11); outside that subtree it is always "TASK".
    private def task_banner_kind : String
      @in_handler_flush ? "RUNNING HANDLER" : "TASK"
    end

    # Runs an include_tasks: task. Unlike import_tasks (spliced into the
    # task list at parse time), this is resolved now: the file path may be
    # templated, and when:/loop: apply to the include statement itself
    # (gating/repeating the whole included set) rather than to each
    # included task individually.
  end
end
