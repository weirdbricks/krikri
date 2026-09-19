require "./executor"

module Krikri
  class TaskExecutor
    private def gather_facts_for_all_hosts : Nil
      # --gathering smart: a host whose facts this run already collected
      # (in an earlier play, via the shared run-scoped store) is not
      # queried again. Under the default `implicit` mode every play
      # re-gathers, matching real ansible-playbook's own default - a
      # playbook that deliberately re-gathers after a reboot or a package
      # install must keep seeing fresh facts, which is exactly why this
      # is opt-in rather than a silent default flip.
      #
      # Also under --gathering smart: a persisted fact-cache
      # (ANSIBLE_CACHE_PLUGIN=jsonfile) is consulted for any host this
      # RUN hasn't already gathered, populating @facts from a still-warm
      # earlier PROCESS's cache the same way an earlier play in this
      # same run would - see FactCache's own comment for why this is
      # gated on smart_gathering specifically (real Ansible's own
      # `implicit` gathering ignores the cache entirely). This is what
      # makes a warm rerun show `ok=0`/no banner for a fully-cached host
      # instead of always re-gathering - see KNOWN_MISSING.md.
      if @smart_gathering && FactCache.enabled?
        @hosts.each do |host|
          next unless @facts[host.name].empty?
          if cached = FactCache.read(host.name)
            @facts[host.name] = cached
            @facts_dict_cache.delete(host.name)
            @hv_generation += 1
          end
        end
      end

      targets = if @smart_gathering
                  @hosts.reject { |host| !@facts[host.name].empty? }
                else
                  @hosts
                end

      # Nothing to do: every host was gathered by an earlier play. Skip
      # the task banner entirely rather than printing an empty one.
      return if targets.empty?

      puts "TASK [Gathering Facts]".colorize(:white).bold
      puts "*" * 70

      # A host the pre-upload pass already found unreachable must NOT get
      # a second live SSH attempt here - real ansible-playbook only ever
      # tries the connection once (inside this very task, since Gathering
      # Facts *is* its first task) and reports that single failure as
      # unreachable=1/failed=0. Retrying produces a second, redundant
      # connection failure that used to get booked as "failed" here AND
      # THEN as "unreachable" again when run_task_batch's own
      # @unreachable_hosts check hit the play's first real task -
      # doubling the recap for what real Ansible counts once. Found via
      # GROG.reboot going DIVERGENT on a dead kata VM: crystal's warm
      # recap showed `unreachable=1 failed=1` against real Ansible's
      # `unreachable=1 failed=0`.
      live_targets = targets.reject { |host| @unreachable_hosts.includes?(host.name) }

      outcomes = Hash(String, {Bool, String?, Bool}).new
      # Bounded by @forks, same as the per-task fan-out below: the `10`
      # this used to hardcode predates --forks, so `--forks 50` still
      # gathered 10 at a time and `--forks 1` (asked for precisely to get
      # strictly one-host-at-a-time behavior, e.g. to debug a flaky host)
      # still got 10-way concurrency here.
      max_parallel = Math.min(live_targets.size, @forks)
      max_parallel = 1 if max_parallel < 1
      gate = Channel(Nil).new(max_parallel)
      max_parallel.times { gate.send(nil) }
      done = Channel(Nil).new

      live_targets.each do |host|
        spawn do
          gate.receive
          outcomes[host.name] = gather_facts_for_host(host)
        ensure
          gate.send(nil)
          done.send(nil)
        end
      end

      live_targets.size.times { done.receive }

      targets.each do |host|
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name

        # A host this pass just DISCOVERED to be unreachable (the facts
        # plugin's own failure was an SSH transport failure, not a module
        # failure) is remembered in @unreachable_hosts - the run-scoped
        # set shared across plays - so later plays report every task
        # against it as unreachable instead of re-attempting a connection
        # that just failed. Booked below exactly like a host the
        # pre-upload pass already knew about: same line, same counters,
        # same halt. Without this, a host that dies between runs (the
        # pre-upload pass short-circuits on the host-state cache without
        # touching the network, so nothing else ever notices) kept
        # running the whole play as generic task failures - found via
        # robertdebock.common's warm rerun against a host the cold run
        # had killed: real ansible-playbook recap'd `unreachable=1
        # failed=0` and halted the host at Gathering Facts, this engine
        # booked `failed=2` and ran on.
        if outcomes[host.name]?.try(&.[2])
          @unreachable_hosts << host.name
        end

        if @unreachable_hosts.includes?(host.name)
          # Same wording/shape as report_unreachable's own banner - this
          # IS that host's unreachable report, just booked from the
          # Gathering Facts task instead of a later one, matching real
          # Ansible's single-event recap for a host that never connects.
          puts %(fatal: [#{host.name}]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh: #{connection_host}", "unreachable": true}).colorize(:red)
          @results[host.name]["unreachable"] += 1
          @halted_hosts << host.name
          next
        end

        success, error_message = outcomes[host.name]

        if success
          puts "ok: [#{connection_host}]".colorize(:green)
          # A successful implicit Gathering Facts task is deliberately NOT
          # counted in the recap - real ansible-core 2.19's recap excludes it
          # entirely (live-verified against 2.19.11: facts + one `command:
          # /bin/true` task recaps ok=1, and facts + zero tasks recaps
          # nothing at all, while an EXPLICIT `setup:` task in the task list
          # counts as ok=1 normally; a FAILED implicit setup does still count
          # as failed=1 and halts the host - case verified live too). The
          # phantom ok= here made every play's recap one ok too high, e.g.
          # round900836 NINEJKH.git: facts + one ignore_errors:-swallowed
          # command failure recapped ok=2 changed=1 here vs real ok=1.
        else
          puts "failed: [#{connection_host}]".colorize(:red)
          puts "  Error gathering facts: #{error_message}".colorize(:red)
          @results[host.name]["failed"] += 1
        end
      end

      puts ""
    end

    # Runs the facts plugin against one host and stores whatever it
    # returns in @facts[host.name]. Returns {success, message,
    # unreachable} - stats/display are handled by the caller afterward,
    # in deterministic host order, not here. `unreachable` is true only
    # when the plugin's failure was an SSH transport failure (the
    # `unreachable` marker interpret_remote_result stamps on exactly
    # those), which the caller books as UNREACHABLE instead of a plain
    # failed task.
    private def gather_facts_for_host(host : Host) : {Bool, String?, Bool}
      TimingProfile.measure("execute.facts", "execute.facts") do
        gather_facts_for_host_measured(host)
      end
    end

    # The failure message for a host whose ansible_connection names no
    # connection plugin (see PluginManager.connection_plugin_not_found?),
    # or nil when the connection resolves (including "unset", which the
    # executor's own local/ssh default covers).
    private def unresolvable_connection_message(host : Host) : String?
      conn_type = host.vars["ansible_connection"]?.try(&.as_s?)
      return nil unless conn_type && PluginManager.connection_plugin_not_found?(conn_type)

      "Task failed: the connection plugin '#{conn_type}' was not found"
    end

    # "Plugin execution failed on remote" alone hides WHY the plugin
    # died - the kata round of 2026-09-10 (36/36 roles) failed facts
    # with a bare exit 127 because the guest image lacked
    # libxml2.so.2, and only manual SSH reproduced the loader error.
    # Surface the plugin's own stderr so the cause is visible at the
    # point of failure.
    private def facts_failure_message(result : JSON::Any) : String
      msg = result["msg"]?.try(&.as_s) || "Unknown error"
      if (stderr = result["stderr"]?.try(&.as_s?)) && !stderr.empty?
        msg += "\n  stderr: #{stderr.strip.lines[0, 10].join("\n  stderr: ")}"
      end
      msg
    end

    private def gather_facts_for_host_measured(host : Host) : {Bool, String?, Bool}
      vars_context = Hash(String, JSON::Any).new
      host.vars.each { |key, value| vars_context[key] = value }

      # Real Ansible resolves the connection plugin for the implicit setup
      # task too - an unresolvable ansible_connection fails Gathering
      # Facts with "the connection plugin 'X' was not found" instead of
      # attempting SSH (the silent fallback below reported a bogus
      # UNREACHABLE for what real Ansible reports as a plain failure).
      if (conn_msg = unresolvable_connection_message(host))
        return {false, conn_msg, false}
      end

      # If this gathers over SSH the wire payload needs
      # ansible_connection=local, so decide that up front and serialize
      # once, instead of serializing, parsing and re-serializing just to
      # inject one key afterwards.
      remote = PluginManager.remote_execution?("facts", host, vars_context)
      wire_vars = vars_context
      if remote
        wire_vars = vars_context.dup
        wire_vars["ansible_connection"] = JSON::Any.new("local")
      end

      # ansible_python_interpreter: real Ansible only exposes this flat
      # magic var when the module actually runs on the CONTROLLER itself
      # (a genuine ansible_connection=local target, where it's just
      # sys.executable) - live-verified against ansible-core 2.19.4 that
      # a real REMOTE SSH target never defines it at all (interpreter
      # discovery happens, prints its own warning, but the result is
      # never surfaced as this var) - `ansible_python_interpreter is
      # defined` is False there. `remote` here is exactly that
      # distinction: true whenever this plugin gets uploaded and
      # executed via a real SSH round trip, matching what the earlier
      # (incorrect) 0.9.652 fix conflated with "always define it,
      # anywhere" - found via geerlingguy.mysql's own `{% if 'python3'
      # in ansible_python_interpreter|default('') %}` idiom picking the
      # wrong (always-defined-by-krikri) branch on a real remote host.
      params = Hash(String, String).new
      params["gather_subset"] = @gather_subset.join(",") unless @gather_subset.empty?
      # gather_timeout/fact_path: the other two play keywords real
      # Ansible forwards into its implicit setup call.
      params["gather_timeout"] = @gather_timeout.to_s if @gather_timeout
      if fact_path = @fact_path
        params["fact_path"] = fact_path
      end
      params["_remote_connection"] = remote.to_s
      params["_first_gather"] = first_gather_for_host?(host).to_s

      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port,
        },
        # gather_subset: is forwarded as a comma-separated list; the
        # facts plugin decides which families to skip.
        "params" => params,
        "vars"   => wire_vars,
      }

      # Fact gathering never runs under become: - this config carries no
      # become:/become_user: fields at all, which is exactly what
      # resolve_become used to read back out of it as {false, nil}.
      result = PluginManager.execute_plugin("facts", config.to_json, host, vars_context, false, nil)

      if Krikri.result_failed_flag(result)
        msg = result["msg"]?.try(&.as_s) || "Unknown error"
        # "Plugin execution failed on remote" alone hides WHY the plugin
        # died - the kata round of 2026-09-10 (36/36 roles) failed facts
        # with a bare exit 127 because the guest image lacked
        # libxml2.so.2, and only manual SSH reproduced the loader error.
        # Surface the plugin's own stderr so the cause is visible at the
        # point of failure.
        if (stderr = result["stderr"]?.try(&.as_s?)) && !stderr.empty?
          msg += "\n  stderr: #{stderr.strip.lines[0, 10].join("\n  stderr: ")}"
        end
        return {false, msg, result["unreachable"]?.try(&.as_bool?) == true}
      end

      if ansible_facts = result["ansible_facts"]?
        facts = Hash(String, JSON::Any).new
        ansible_facts.as_h.each { |key, value| facts[key] = value }
        @facts[host.name] = facts
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
        FactCache.write(host.name, facts) if @smart_gathering
      end

      {true, nil, false}
    rescue ex
      {false, ex.message, false}
    end

    # Real Ansible's setup result carries `discovered_interpreter_python`
    # (the interpreter its own discovery resolved) exactly ONCE per host
    # per run - the first module invocation where discovery runs, and it
    # is exempt from the module's own filter (podman-diff setup case W1:
    # real returns ansible_facts = {discovered_interpreter_python} for a
    # filter matching nothing); later invocations find the discovery
    # already cached and never re-emit it (real W2+). This engine's
    # gatherer has no per-host state, so the executor computes the
    # first-gather gate here and threads it to the plugin under
    # _first_gather (see build_plugin_config): a W1-style filtered merge
    # stores the stamp alone, which must count as "already discovered"
    # for the next invocation's gate.
    private def first_gather_for_host?(host : Host) : Bool
      store = @facts[host.name]?
      store.nil? || (store["ansible_python"]?.nil? && store["discovered_interpreter_python"]?.nil?)
    end

    # Show execution recap
    private def merge_ansible_facts(host : Host, result : JSON::Any, high_precedence : Bool = false) : Nil
      return unless ansible_facts = result["ansible_facts"]?
      return unless facts_hash = ansible_facts.as_h?

      # host here can be a `delegate_to:` + `delegate_facts: true` target
      # (xe0nic.ansible_vprotect_server's own `delegate_to: localhost` /
      # `delegate_facts: true` idiom for stashing a computed FQDN onto
      # "localhost") rather than one of the play's own hosts - those only
      # get pre-seeded into @facts/@set_facts for the play's ACTUAL hosts
      # (executor.cr's own per-host init loop), so an arbitrary delegate
      # target crashed the whole process with "Missing hash key" the
      # first time anything delegated a fact to it.
      @facts[host.name] ||= {} of String => JSON::Any
      @set_facts[host.name] ||= {} of String => JSON::Any

      facts_hash.each do |key, value|
        @facts[host.name][key] = value
        @set_facts[host.name][key] = value if high_precedence
      end
      @facts_dict_cache.delete(host.name)
      @hv_generation += 1
    end

    # with_first_found: yields exactly one item - the first candidate path
    # that exists on the *controller* - or none at all when nothing
    # matched. Candidates are templated, so they can only be resolved
    # here, not at parse time.
    private def register_reachable_unavailable_module(task : Task, vars_context : Hash(String, JSON::Any), host : Host, shared : VarSubstitutor? = nil) : Nil
      return unless module_name = task.unavailable_module

      would_run = begin
        when_condition = task.when_condition
        when_condition.nil? || evaluate_when_items(task, vars_context, host, shared)
      rescue
        false
      end
      reachable_unavailable_modules << module_name if would_run
    end
  end
end
