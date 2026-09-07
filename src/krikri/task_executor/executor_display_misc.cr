require "./executor"

module Krikri
  class TaskExecutor
    private def report_unreachable(task : Task, host : Host) : Nil
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      puts %(fatal: [#{host.name}]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh: #{connection_host}", "unreachable": true}).colorize(:red)

      stats = @results[host.name]
      if task.ignore_unreachable?
        # Counted as ok AND ignored, matching real Ansible's own recap
        # for an ignored unreachable task.
        stats["ok"] += 1
        stats["ignored"] += 1
      else
        stats["unreachable"] += 1
        @halted_hosts << host.name
      end
    end

    def show_recap : Nil
      ResultDisplay.show_recap(@hosts, @results)
    end

    # Execute a task on a host - dispatches to the loop, retry, or plain
    # single-execution path depending on what the task declares.
    private def render_task_name_for_display(task : Task, host : Host) : String
      return task.name unless task.name.includes?("{{")

      vars_context = build_vars_context(task, host)
      VarSubstitutor.new(vars: vars_context, host_name: host.name).substitute(task.name)
    rescue
      task.name
    end

    # The "myrole : " prefix real Ansible puts on a role-sourced task's
    # own TASK banner (verified live against ansible-core 2.19.12:
    # `TASK [myrole : Install packages]`, and a NAMELESS role task gets
    # it too, e.g. `TASK [myrole : debug]` - matching the already-fixed
    # action-derived fallback name from KNOWN_MISSING.md's "Generic
    # TASK [Task 1] label" entry). Display-only: task.name itself stays
    # bare (this helper is deliberately NOT folded into
    # #render_task_name_for_display, which HandlerRunner also uses as
    # its own name_resolver for notify: MATCHING bookkeeping, not just
    # display - prefixing that shared function would make a plain
    # `notify: my handler` stop matching a role handler's now-prefixed
    # rendered_name; see handler_runner.cr's own separate, matching-
    # safe prefix-at-print-time fix for the HANDLER banner).
    #
    # `include_role:`/`import_role:` tasks are the one documented
    # exception - real Ansible never prefixes the include/import task
    # itself with its OWN enclosing role's name (only what it expands
    # INTO inherits the new role's prefix): verified live, a NAMED
    # `include_role:` task inside "myrole" showed just its own name,
    # no "myrole :" prefix at all.
    private def execute_async(task : Task, exec_host : Host, config_json : String, vars : Hash(String, JSON::Any), substitutor : VarSubstitutor? = nil, substituted_become_user : String? = nil) : JSON::Any
      is_local = exec_host.vars["ansible_connection"]?.try(&.as_s?) == "local" || exec_host.name == "localhost" || exec_host.name == "127.0.0.1"
      unless is_local
        return execute_remote_async(task, exec_host, config_json, vars, substitutor, substituted_become_user)
      end

      jid = AsyncJobs.generate_jid
      AsyncJobs.write_status(jid, JSON.parse({
        "started"        => 1,
        "finished"       => 0,
        "ansible_job_id" => jid,
      }.to_json))
      File.write(AsyncJobs.config_path(jid), config_json)
      # The config carries full module params (potentially secrets) - the
      # job files live under a predictable shared path, so 0600.
      File.chmod(AsyncJobs.config_path(jid), 0o600)
      File.chmod(AsyncJobs.status_path(jid), 0o600)

      executable = Process.executable_path || File.join(Dir.current, "krikri-playbook")
      Process.new(
        executable,
        ["__async_run", task.module_name, AsyncJobs.config_path(jid), AsyncJobs.status_path(jid)],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      poll = task.poll_seconds || 10
      if poll <= 0
        return JSON.parse({
          "changed"        => true,
          "started"        => 1,
          "finished"       => 0,
          "ansible_job_id" => jid,
          "msg"            => "Job started: #{jid}",
        }.to_json)
      end

      deadline = Time.instant + (task.async_seconds || raise "BUG: async_seconds missing").seconds
      loop do
        sleep poll.seconds
        if status = AsyncJobs.read_status(jid)
          return status if AsyncJobs.finished?(status)
        end
        break if Time.instant >= deadline
      end

      JSON.parse({
        "changed"        => false,
        "failed"         => true,
        "msg"            => "async task did not complete within #{task.async_seconds} seconds",
        "ansible_job_id" => jid,
      }.to_json)
    end

    # The remote-connection half of async: - see execute_async's own
    # comment. Detached launch (poll: 0 returns immediately, real
    # fire-and-forget semantics: the `shutdown -r now` idiom kills the
    # SSH session the moment it starts, which is the point) plus an
    # optional poll loop reading the job's status file back over SSH.
    private def execute_remote_async(task : Task, exec_host : Host, config_json : String, vars : Hash(String, JSON::Any), substitutor : VarSubstitutor?, substituted_become_user : String?) : JSON::Any
      # Same become resolution + validation the non-async remote path
      # applies at its own call site.
      become = false
      become_user = nil
      if substitutor && resolve_task_become(task, substitutor)
        become = true
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

      PluginManager.ensure_uploaded(exec_host, task.module_name, vars)
      target = PluginManager.remote_plugin_target(task.module_name, become, become_user, exec_host.user || "root")
      connection_host = PluginManager.get_connection_host(exec_host, vars)
      user = exec_host.user || "root"
      identity_file = vars["ansible_ssh_private_key_file"]?.try(&.as_s?)

      jid = AsyncJobs.generate_jid
      dir = "~/.ansible_async"
      encoded = Base64.strict_encode(config_json)
      # base64 alphabet can't break shell quoting; the tmp+mv makes the
      # status file's appearance atomic for the poll loop below (a
      # partial stdout write would otherwise parse as garbage mid-read).
      launch = <<-SCRIPT
        mkdir -p #{dir}
        echo '#{encoded}' | base64 -d > #{dir}/#{jid}.cfg
        nohup sh -c '#{target} < #{dir}/#{jid}.cfg > #{dir}/#{jid}.tmp 2>&1; mv #{dir}/#{jid}.tmp #{dir}/#{jid}' >/dev/null 2>&1 &
      SCRIPT

      launched = SSHManager.exec_script(connection_host, user, launch, exec_host.port, identity_file: identity_file)
      if launched[:exit_code] != 0
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "remote async launch failed: #{launched[:stderr].strip}",
        }.to_json)
      end

      poll = task.poll_seconds || 10
      if poll <= 0
        return JSON.parse({
          "changed"        => true,
          "started"        => 1,
          "finished"       => 0,
          "ansible_job_id" => jid,
          "msg"            => "Job started: #{jid}",
        }.to_json)
      end

      deadline = Time.instant + (task.async_seconds || raise "BUG: async_seconds missing").seconds
      loop do
        sleep poll.seconds
        check = SSHManager.exec_script(connection_host, user, "cat #{dir}/#{jid} 2>/dev/null", exec_host.port, identity_file: identity_file)
        if (output = check[:stdout].strip).size > 0
          if status = (JSON.parse(output) rescue nil)
            return status
          end
        end
        break if Time.instant >= deadline
      end

      JSON.parse({
        "changed"        => false,
        "failed"         => true,
        "msg"            => "async task did not complete within #{task.async_seconds} seconds",
        "ansible_job_id" => jid,
      }.to_json)
    end

    # ansible.builtin.reboot - entirely unimplemented before (silently
    # dropped at parse time, "Plugin not available"). Architecturally
    # can't be a normal plugin binary the way every other module here
    # works: those get uploaded to and run ON the target host, but a
    # reboot module's own process would die the instant the machine it's
    # running on actually reboots, before it could ever report back.
    # Real Ansible's own reboot module is a controller-side ACTION
    # plugin for exactly this reason - it issues the reboot command,
    # then polls the CONNECTION (not the remote process) until the host
    # goes away and comes back. Handled entirely here instead: issues
    # reboot_command over one SSH call (tolerating the connection dying
    # mid-command, which is the expected/successful outcome), waits
    # post_reboot_delay, then polls a trivial remote command (test_command
    # if given, else a bare `whoami`) until it succeeds or reboot_timeout
    # is exceeded. Found via robertdebock.common's own "Reboot" handler
    # (notified by "Set hostname"/"Fill /etc/hosts", `common_reboot:
    # true` by default) and robertdebock.update's own reboot-on-upgrade
    # handler - both very common real-world idioms, not narrow ones.
    #
    # local connection is intentionally left alone (returns changed:
    # false, failed: true) - rebooting the controller process's own
    # machine out from under itself has no safe/sane implementation here
    # and real Ansible's own module warns heavily against it too.
    # group_by: - like reboot:, has no uploaded plugin binary at all
    # (listed in AVAILABLE_PLUGINS purely so the task isn't dropped at
    # parse time as "Plugin not available"). Real Ansible implements it
    # as an action plugin that mutates the live inventory rather than
    # running anything on the target - mirrored here by mutating the
    # shared Inventory instance krikri-playbook.cr passes to every play's
    # TaskExecutor (the SAME object across the whole per-play loop, not
    # a copy - a later play's `hosts:` pattern lookup sees whatever
    # group membership an earlier play's group_by: task added). `key:`
    # may itself be comma-separated (a rarely-used real Ansible feature:
    # one task adding the host to several groups at once); `parents:` is
    # accepted and recorded via HostGroup#add_child for completeness,
    # though this codebase's own Inventory#get_hosts never actually
    # walks group hierarchy (only exact group-name matches), so it's
    # inert beyond documentation today - same limitation static
    # inventory group parent/child nesting already has here.
    private def execute_set_stats(params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      data_json = params["data"]?
      if data_json.nil? || data_json.empty?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "missing required argument: data"}.to_json)
      end

      data = JSON.parse(data_json) rescue nil
      unless data && data.as_h?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "data must be a dictionary of stat name -> value"}.to_json)
      end

      aggregate = !["false", "no", "0", "off"].includes?(params["aggregate"]?.try(&.downcase))
      per_host = ["true", "yes", "1", "on"].includes?(params["per_host"]?.try(&.downcase))

      data.as_h.each do |key, value|
        CustomStats.set(key, value, aggregate, host.name, per_host)
      end

      JSON.parse({"changed" => false, "failed" => false, "msg" => ""}.to_json)
    end

    private def debug_if_requested(task : Task, host : Host, result : JSON::Any) : JSON::Any
      setting = task.debugger || @debugger
      return result unless TaskDebugger.triggered?(setting, result)

      current = result
      # `task_vars[...] = v` typed at the prompt lands here once
      # `u`/`update_task` promotes it, and is merged into the context
      # every subsequent redo builds - real Ansible's own semantics,
      # where a task_vars edit changes nothing until `u` re-templates
      # the task (verified against ansible-core 2.19.4: assign + `r`
      # alone re-runs the ORIGINAL command).
      var_overrides = Hash(String, JSON::Any).new
      loop do
        debug_vars = build_vars_context(task, host)
        var_overrides.each { |key, value| debug_vars[key] = value }

        case TaskDebugger.run(render_task_name_for_display(task, host), host.name, current,
          debug_vars, task, var_overrides)
        in TaskDebugger::Outcome::Continue
          return current
        in TaskDebugger::Outcome::Redo
          # `r` re-runs the task and re-evaluates the trigger against the
          # new result, so a still-failing task prompts again - which is
          # the point of being able to fix something and retry.
          rerun_vars = build_vars_context(task, host)
          var_overrides.each { |key, value| rerun_vars[key] = value }
          rerun = execute_task_once(task, host, rerun_vars)
          current = rerun if rerun
          return current unless TaskDebugger.triggered?(setting, current)
        end
      end
    end

    private def item_label_for(task : Task, item : JSON::Any, vars_context : Hash(String, JSON::Any), host : Host) : String
      if label = task.loop_label
        rendered = VarSubstitutor.new(vars: vars_context, host_name: host.name).substitute(label) rescue nil
        return rendered if rendered
      end
      item_display(item)
    end

    private def item_display(item : JSON::Any) : String
      item.raw.is_a?(String) ? item.as_s : item.to_json
    end

    # Whether *host*'s `meta: end_role` already ended the role *task*
    # belongs to. Identity: the role invocation - a dynamic include_role
    # run stamps its freshly-loaded tasks with a per-invocation token
    # (Task#role_invocation_id), so two invocations of the same role are
    # independent; a statically loaded role (roles:/import_role:) keys on
    # its filesystem root (task.role_path), which is unique per play
    # there. Tasks outside any role are never affected.
    private def role_ended_for_host?(task : Task, host : Host) : Bool
      key = task.role_invocation_id || task.role_path
      return false unless key
      ended = @role_ended_hosts[key]?
      ended ? ended.includes?(host.name) : false
    end

    # Run a task repeatedly (up to task.retries times, sleeping task.delay
    # seconds between attempts) until task.until_condition evaluates true
    # against the registered result, matching Ansible's until:/retries:/delay:.
    # Skipped entirely in check mode: most modules refuse to act in check
    # mode anyway, which would otherwise turn every retry loop into a slow,
    # guaranteed-to-fail wait for no reason.
    private def execute_meta(task : Task, host : Host) : Nil
      case task.meta_action
      when "flush_handlers"
        # Called once per host by the outer per-task host loop in #run,
        # but @tasks.each is sequential across tasks - every active host
        # has already finished every task BEFORE this one by the time any
        # of them reaches it, so running the full (cross-host)
        # HandlerRunner#run here is correct regardless of which host
        # triggers it first. Subsequent per-host calls for this same
        # meta task are harmless no-ops: HandlerRunner#run clears each
        # host's notified set after running, so any_notified? is false
        # for the 2nd..Nth host and #run returns immediately without
        # re-printing anything.
        run_handlers
      when "end_host"
        # Per-host - verified against real ansible-playbook: a 2nd host
        # whose own `when:` makes it skip this exact task entirely keeps
        # running normally afterward, unlike end_play below. Reuses
        # halted_hosts (already excludes this host from every remaining
        # task in this play, including nested block:/rescue:/always:,
        # and - also verified live - suppresses its own pending notified
        # handlers at the end-of-play flush, exactly like a real
        # failure) but tracked separately in ended_hosts so it's NOT
        # treated as a failure for the exit code or carried forward into
        # later plays.
        @halted_hosts.add(host.name)
        @ended_hosts.add(host.name)
      when "end_play"
        # Global, NOT per-host - verified against real ansible-playbook:
        # even a host whose own `when:` skips this exact task entirely
        # (never itself executes this branch) still gets halted for the
        # rest of the play the moment ANY other host does. So this halts
        # every currently-active host in the whole play, not just
        # `host` - @hosts is the play's own full host list, available on
        # the executor regardless of which single host's fiber is
        # running this code.
        @hosts.each do |other|
          next if @halted_hosts.includes?(other.name)
          @halted_hosts.add(other.name)
          @ended_hosts.add(other.name)
        end
      when "clear_host_errors"
        # Global, NOT scoped to `host` - same shape as end_play above,
        # and for the same reason: real Ansible's own doc wording
        # ("clears the failed state from hosts specified in the PLAY'S
        # LIST OF HOSTS") and live verification both show it acts on
        # every failed host in the play, not just whichever host(s)
        # happen to still be active enough to individually execute this
        # meta task - a host that already failed earlier in this play is
        # EXCLUDED from this task too (same halted_hosts gate as any
        # other), so if clearing were scoped to `host` alone, the failed
        # host itself could never reach this code to clear its own
        # error, making the feature unusable exactly the way the
        # community.general docs' own example uses it (a failing task
        # immediately followed by clear_host_errors in the same task
        # list). Also confirmed live: clears the failure for SUBSEQUENT
        # plays (the failed host is back for play 2) but leaves
        # halted_hosts itself untouched, so the current play still does
        # not resume for that host - matching "does NOT continue
        # execution in the current play" exactly.
        @hosts.each do |other|
          @cleared_error_hosts.add(other.name) if @halted_hosts.includes?(other.name)
        end
      when "end_batch"
        # Real Ansible's end_batch ends the current `serial:` batch (all
        # its hosts, like end_play but without the end_play flag). This
        # engine doesn't model serial batching - one batch per play - so
        # end_batch IS end_play here (verified against ansible-core
        # 2.19.4's own strategy code: both call iterator.end_host for
        # every host in the play; only end_play additionally raises
        # AnsibleEndPlay, which the playbook executor handles by ending
        # THIS play only - so the observable behavior matches).
        @hosts.each do |other|
          next if @halted_hosts.includes?(other.name)
          @halted_hosts.add(other.name)
          @ended_hosts.add(other.name)
        end
      when "end_role"
        # Per-host role-scoped early return (ansible-core 2.18+). Real
        # Ansible consumes the role's remaining tasks for this host
        # silently in the iterator - no banners, no recap counters - and
        # stops at the role's implicit `role_complete` boundary, so
        # parent roles and role dependencies are unaffected. Keyed on
        # the role INVOCATION (Task#role_invocation_id for a dynamic
        # include_role, the role path for a static one): verified against
        # ansible-core 2.19.4 that a looped include_role whose first
        # item ends the role still runs the second item in full.
        if key = task.role_invocation_id || task.role_path
          ended = (@role_ended_hosts[key] ||= Set(String).new)
          ended.add(host.name)
        else
          # Real Ansible rejects end_role outside a role at PARSE time
          # ("Cannot execute 'end_role' from outside of a role") - a
          # play-level one is caught before any play runs
          # (krikri-playbook.cr's own flattened-list check); this branch
          # only covers one reached through a dynamic include_tasks:
          # body, where the file is loaded too late for that check.
          # Fails the task for this host instead of aborting the run -
          # the same "which tasks ran" divergence the role-private
          # custom-module scope cut already documents.
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "failed: [#{connection_host}]".colorize(:red)
          puts "  Cannot execute 'end_role' from outside of a role".colorize(:red)
          @results[host.name]["failed"] += 1
          @halted_hosts.add(host.name)
        end
      when "reset_connection"
        # Drop the host's persistent connection state (resident plugin
        # daemons + ssh ControlMaster sockets); the next task reopens
        # fresh connections. Real Ansible's result carries msg
        # "reset connection" (or "no connection, nothing to reset") and
        # counts in no recap bucket - a META: vv line only - so nothing
        # is printed or counted here either.
        SSHManager.reset_connection(host.name)
      when "noop"
        # Real Ansible's own doc: "this literally does 'nothing'."
      when "refresh_inventory"
        # Real Ansible's own doc, verified live: refreshing does NOT add
        # hosts to (or remove them from) the CURRENT play's own host
        # loop - only a LATER play's own `hosts:` pattern match sees the
        # new data, since that's computed fresh from the shared
        # Inventory object each time (krikri-playbook.cr's own per-play
        # `matched_hosts = inventory.get_hosts(...)`). Re-parsing and
        # reload_from!-ing in place (rather than just swapping in a new
        # Inventory reference) is what makes that "shared object" premise
        # true without any callback plumbing back up to krikri-playbook.cr -
        # see Inventory#reload_from!'s own comment. A no-op (not an
        # error) when no inventory_path was given - the `ansible` ad-hoc
        # CLI's own TaskExecutor never passes one, and a single synthetic
        # ad-hoc task has no later play to ever observe a refresh anyway.
        if (path = @inventory_path) && (inv = @inventory)
          inv.reload_from!(InventoryParser.parse(path))
          @hv_generation += 1
        end
      else
        # Only clear_facts/flush_handlers/end_host/end_play/
        # clear_host_errors/noop/refresh_inventory parse (see
        # PlaybookParser.parse_meta_task), so clear_facts is the only
        # other action to dispatch on here. Confirmed via cli_spec.cr's
        # own pre-existing "reflects a register:/set_fact:/meta:
        # clear_facts... in another host's hostvars" spec: real
        # ansible-playbook's clear_facts drops a plain (non-cacheable)
        # set_fact value too, not just gathered facts - so @set_facts
        # is cleared right alongside @facts to keep the two stores
        # consistent (a ghost @set_facts entry would otherwise keep
        # getting injected at the high tier after the clear).
        @facts[host.name].clear
        @set_facts[host.name].clear
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
      end
    end
  end
end
