require "./executor"

module Krikri
  class TaskExecutor
    private def gather_facts_for_all_hosts : Nil
      # --gathering smart: a host whose facts this run already collected
      # (in an earlier play, via the shared run-scoped store) is not
      # queried again. Under the default `implicit` mode every play
      # re-gathers (merging over the shared store), matching
      # ansible-playbook's own default - a playbook that deliberately
      # re-gathers after a reboot or a package install must keep seeing
      # fresh facts, which is exactly why this is opt-in rather than a
      # silent default flip.
      #
      # Also under --gathering smart: a persisted fact-cache
      # (ANSIBLE_CACHE_PLUGIN=jsonfile) is consulted for any host this
      # RUN hasn't already gathered, populating @facts from a still-warm
      # earlier PROCESS's cache the same way an earlier play in this
      # same run would - see FactCache's own comment for why this is
      # gated on smart_gathering specifically (Ansible's own
      # `implicit` gathering ignores the cache entirely). This is what
      # makes a warm rerun show `ok=0`/no banner for a fully-cached host
      # instead of always re-gathering - see KNOWN_MISSING.md.
      if @smart_gathering && FactCache.enabled?
        @hosts.each do |host|
          next if gathered_facts_for?(host)
          if cached = FactCache.read(host.name)
            @facts[host.name] = cached
            @facts_dict_cache.delete(host.name)
            @hv_generation += 1
          end
        end
      end

      targets = if @smart_gathering
                  @hosts.reject { |host| gathered_facts_for?(host) }
                else
                  @hosts
                end

      # Nothing to do: every host was gathered by an earlier play. Skip
      # the task banner entirely rather than printing an empty one.
      return if targets.empty?

      Krikri::OutputBanner.banner("TASK [Gathering Facts]")
      # The implicit facts task is a real task to the profile_tasks
      # callback (its own recap row, live-verified), banner or no banner.
      Krikri::ProfileTasks.record_task_start(Krikri::ProfileTasks::FACTS_TASK_IDENTITY, "Gathering Facts")
      # Real -vv labels the implicit facts task's `task path:` with the
      # play's own location, not a task line.
      if Krikri::RunOptions.verbosity >= 2 && (file = @play_source_file) && @play_source_line > 0
        puts "task path: #{File.expand_path(file)}:#{@play_source_line}"
      end

      # A host the pre-upload pass already found unreachable must NOT get
      # a second live SSH attempt here - ansible-playbook only ever
      # tries the connection once (inside this very task, since Gathering
      # Facts *is* its first task) and reports that single failure as
      # unreachable=1/failed=0. Retrying produces a second, redundant
      # connection failure that used to get booked as "failed" here AND
      # THEN as "unreachable" again when run_task_batch's own
      # @unreachable_hosts check hit the play's first real task -
      # doubling the recap for what Ansible counts once. Found via
      # GROG.reboot going DIVERGENT on a dead kata VM: crystal's warm
      # recap showed `unreachable=1 failed=1` against Ansible's
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

      # SSH transport error detail per host whose gather failed at the
      # transport level THIS pass - feeds the unreachable report's msg.
      fresh_ssh_errors = Hash(String, String).new

      targets.each do |host|
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
        # had killed: ansible-playbook recap'd `unreachable=1
        # failed=0` and halted the host at Gathering Facts, this engine
        # booked `failed=2` and ran on.
        if outcomes[host.name]?.try(&.[2])
          @unreachable_hosts << host.name
          fresh_ssh_errors[host.name] = outcomes[host.name][1] || ""
        end
      end

      # Unreachable hosts report FIRST: a refused connection completes
      # long before a successful gather, so ansible's result order puts
      # the fatal line ahead of the successful hosts' ok lines
      # (live-verified vs ansible-core 2.19.11).
      targets.each do |host|
        next unless @unreachable_hosts.includes?(host.name)
        # Same wording/shape as report_unreachable's own banner - this
        # IS that host's unreachable report, just booked from the
        # Gathering Facts task instead of a later one, matching
        # Ansible's single-event recap for a host that never connects.
        # A transport failure discovered HERE carries this attempt's
        # own ssh error; a host the pre-upload pass already knew about
        # carries that pass's recorded one.
        report_unreachable(nil, host, fresh_ssh_errors[host.name]? || @unreachable_ssh_errors[host.name]?)
      end

      targets.each do |host|
        next if @unreachable_hosts.includes?(host.name)

        success, error_message = outcomes[host.name]

        if success
          if Krikri::Oneline.enabled? && (facts_result = @facts_results[host.name]?)
            # The oneline callback renders the WHOLE setup result as the
            # host's line (`host | SUCCESS => {...facts...}`, live-
            # verified) - the default callback's bare `ok: [host]` is not
            # what oneline prints.
            Krikri::Oneline.display_result(host, facts_result, module_name: "setup")
          else
            puts "ok: [#{host.name}]".colorize(:green)
          end
          # A successful implicit Gathering Facts task DOES count as ok=1 in
          # the recap - ansible-core 2.19.11 recaps ok=2 for facts + one
          # command task, ok=1 for a task-less play, and ok=4 for 2 gathers +
          # 2 debug tasks (all verified live, cache-free: with this box's
          # ambient ANSIBLE_GATHERING=smart + a warm fact cache Ansible
          # silently SKIPS Gathering Facts on a rerun - no banner, no recap
          # contribution - which is how the "facts never count" model was
          # once wrongly inferred from a masked rerun). A FAILED implicit
          # setup still counts failed=1 and halts the host, and an explicit
          # `setup:` task counts normally.
          @results[host.name]["ok"] += 1
        else
          if missing = @facts_interpreter_missing[host.name]?
            interp, remote, dash_shell = missing
            # Ansible prints a full failed-setup block for a missing
            # module interpreter (cause chain, sub-event box, fatal line
            # with the failed_modules payload) - not the generic two-line
            # failure report. The fatal line gets the red tint like every
            # neighbouring fatal line; the block's other lines stay plain.
            report_lines = Krikri::FactsGatherer.interpreter_missing_report(host.name, interp, host.connection_host, remote, dash_shell).split("\n")
            fatal_line = report_lines.pop
            report_lines.each { |line| puts line }
            puts fatal_line.colorize(:red)
          else
            puts "failed: [#{host.name}]".colorize(:red)
            puts "  Error gathering facts: #{error_message}".colorize(:red)
          end
          @results[host.name]["failed"] += 1
          # A failed implicit setup halts the host like any failed task -
          # ansible-playbook runs none of the play's tasks on it afterwards.
          @halted_hosts.add(host.name)
        end
      end
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

    # The effective ansible_python_interpreter for the implicit setup
    # task: Ansible applies role defaults at gather time too, and krikri
    # stores role defaults unrendered, so the value may itself be Jinja
    # (e.g. "{{ pypy_dir }}/bin/python"). Host vars win over role
    # defaults, matching Ansible's precedence.
    private def effective_python_interpreter(host : Host, vars_context : Hash(String, JSON::Any)) : String?
      return nil unless host.vars.has_key?("ansible_python_interpreter") ||
                        @all_role_defaults.has_key?("ansible_python_interpreter")

      context = vars_context.dup
      @all_role_defaults.each { |key, value| context[key] ||= value }
      raw = context["ansible_python_interpreter"]?
      return nil unless raw

      rendered = render_task_var_value(raw, context, host.name)
      value = rendered.as_s?
      return nil unless value && !value.empty?
      value
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

      # Ansible resolves the connection plugin for the implicit setup
      # task too - an unresolvable ansible_connection fails Gathering
      # Facts with "the connection plugin 'X' was not found" instead of
      # attempting SSH (the silent fallback below reported a bogus
      # UNREACHABLE for what Ansible reports as a plain failure).
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

      # ansible_python_interpreter: Ansible only exposes this flat
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
      # gather_timeout/fact_path: the other two play keywords
      # Ansible forwards into its implicit setup call.
      params["gather_timeout"] = @gather_timeout.to_s if @gather_timeout
      if fact_path = @fact_path
        params["fact_path"] = fact_path
      end
      params["_remote_connection"] = remote.to_s
      params["_first_gather"] = first_gather_for_host?(host).to_s
      # Ansible's setup module runs under the host's configured
      # ansible_python_interpreter (host vars or role defaults, which
      # Ansible applies at implicit-gather time) and fails Gathering
      # Facts with rc 127 when it is missing on the target - the facts
      # plugin performs that check there.
      if interpreter = effective_python_interpreter(host, vars_context)
        params["ansible_python_interpreter"] = interpreter
      end

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
        # The gatherer marks an rc-127 interpreter-not-found failure with
        # the configured path itself - remember it (and whether this ran
        # over SSH, which decides which shell-error form ansible shows,
        # and whether the target's /bin/sh is dash, which decides that
        # form's wording) so the report below can print the real fatal
        # block.
        if (interp = result["interpreter_missing"]?.try(&.as_s?)) && !interp.empty?
          dash = result["shell_dash"]?.try(&.as_bool?) == true
          @facts_interpreter_missing[host.name] = {interp, remote, dash}
        end
        return {false, msg, result["unreachable"]?.try(&.as_bool?) == true}
      end

      if ansible_facts = result["ansible_facts"]?
        @facts_results[host.name] = result
        # A later successful gather clears any stale interpreter-failure
        # stamp, so the report below never prints for a host whose facts
        # eventually came through.
        @facts_interpreter_missing.delete(host.name)
        facts = Hash(String, JSON::Any).new
        ansible_facts.as_h.each { |key, value| facts[key] = value }
        # Merge, not replace: with the run-scoped fact store this host may
        # already carry facts/set_facts from earlier plays of this run, and
        # Ansible's own re-gather merges the fresh discovery OVER the
        # existing fact cache (set_facts and earlier gathered facts
        # survive; verified against ansible-core 2.19.11). Under the old
        # per-play store the incoming hash started empty, so replace and
        # merge were indistinguishable there.
        @facts[host.name] ||= {} of String => JSON::Any
        facts.each { |key, value| @facts[host.name][key] = value }
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
        FactCache.write(host.name, facts) if @smart_gathering
      end

      {true, nil, false}
    rescue ex
      {false, ex.message, false}
    end

    # Whether *host* has any GATHERED fact this run - a fact that came
    # from fact gathering, not from a high-precedence set_fact. The two
    # used to be the same question because the pre-gather check ran on a
    # per-play store that was always empty of set_facts at gather time;
    # with the run-scoped store a play-1 set_fact alone must NOT count as
    # "already gathered" for --gathering smart (Ansible's smart
    # gathering consults the fact cache, which set_facts don't enter
    # unless cacheable: yes). merge_ansible_facts writes every
    # high-precedence key into BOTH stores, so "every @facts key is also
    # a @set_facts key" means "set_facts only".
    private def gathered_facts_for?(host : Host) : Bool
      facts = @facts[host.name]?
      return false if facts.nil? || facts.empty?
      set_names = @set_facts[host.name]?
      facts.keys.any? { |key| set_names.nil? || !set_names.has_key?(key) }
    end

    # Ansible's setup result carries `discovered_interpreter_python`
    # (the interpreter its own discovery resolved) exactly ONCE per host
    # per run - the first module invocation where discovery runs, and it
    # is exempt from the module's own filter (podman-diff setup case W1:
    # Ansible returns ansible_facts = {discovered_interpreter_python} for a
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
    private def merge_ansible_facts(host : Host, result : JSON::Any, high_precedence : Bool = false, task : Task? = nil) : Nil
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
      @set_fact_origins[host.name] ||= {} of String => VarOrigin

      facts_hash.each do |key, value|
        @facts[host.name][key] = value
        if high_precedence
          @set_facts[host.name][key] = value
          # set_fact's own result is applied here (real's
          # vars/manager.py set_host_facts), which is where real warns -
          # before that task's ok: line - for a reserved-name key; the
          # merge only runs for an applied result, so a skipped task
          # stays silent like real's skipped-task path.
          warn_reserved_set_fact_key(task, key) if task
          # The value token's position in the set_fact task's own source
          # file - real's data lineage for a set_fact-sourced value
          # points there (unlike a gathered fact or registered result,
          # which get the conditional's own token). A key the scan cannot
          # locate simply gets no origin.
          if task && (origin = set_fact_value_origin(task, key))
            @set_fact_origins[host.name][key] = origin
          end
        end
        # Write-time unsafe marking (the per-task context build marks these
        # stores too, but a host that never executes again would otherwise
        # never get its write marked - see VarSubstitutor.
        # add_resolved_var_name's comment). Value-level for every fact;
        # the NAME-level registry addition is for high-precedence set_fact
        # keys only, which the context build registers unconditionally -
        # a bare fact key must not gate an author var that happens to
        # share its name.
        UnsafeValues.mark_value(value)
        VarSubstitutor.add_resolved_var_name(host.name, key) if high_precedence
      end
      @facts_dict_cache.delete(host.name)
      @hv_generation += 1
    end

    # Real (2.19, live-verified) prints, on stderr immediately before the
    # set_fact task's ok: line, the same reserved-name warning the
    # vars:-key path emits - "[WARNING]: Found variable using reserved
    # name '<key>'." plus the key's own Origin block and a blank line -
    # once per key position per run (Display.warning's dedup). The Origin
    # scan is ResultDisplay.set_fact_key_origin's; merge_ansible_facts
    # runs inside concurrent per-host fibers, so the dedup set needs the
    # mutex like playbook_parser.cr's @@reserved_toplevel_var_warnings.
    @@reserved_set_fact_warnings = Set(String).new
    RESERVED_SET_FACT_WARN_MUTEX = Mutex.new

    private def warn_reserved_set_fact_key(task : Task, key : String) : Nil
      return unless PlaybookParser::RESERVED_VAR_NAMES.includes?(key)
      return unless origin = ResultDisplay.set_fact_key_origin(task, key)
      dedup_key = "#{key}\n#{origin}"
      RESERVED_SET_FACT_WARN_MUTEX.synchronize do
        return if @@reserved_set_fact_warnings.includes?(dedup_key)
        @@reserved_set_fact_warnings << dedup_key
        STDERR.puts "[WARNING]: Found variable using reserved name '#{key}'."
        STDERR.puts origin
        STDERR.puts
      end
    end

    # with_first_found: yields exactly one item - the first candidate path
    # that exists on the *controller* - or none at all when nothing
    # matched. Candidates are templated, so they can only be resolved
    # here, not at parse time.

    # The VALUE token's position for a set_fact mapping key named `key`:
    # the first character after the key's colon, quote included - the
    # position real's data lineage reports for a set_fact-sourced value
    # (live-verified 2.19.11: `user: setfact_value` reports the value's
    # column, not the key's). Same best-effort line scan as
    # ResultDisplay's set_fact_key_origin (quoted keys carry their colon
    # after the closing quote; only a whitespace-prefixed mapping key
    # matches), but pointing at the value like task_param_value_origin.
    private def set_fact_value_origin(task : Task, key : String) : FileVarOrigin?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)

      lines = File.read_lines(path)
      needles = {"\"#{key}\":", "'#{key}':", "#{key}:"}
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        at = needles.compact_map { |needle| line.index(needle) }.min?
        next unless at
        # only a mapping key: nothing but whitespace before it
        next unless line[0...at].strip.empty?
        col = at + line[at..].index!(':') + 1
        while col < line.size && line[col] == ' '
          col += 1
        end
        if col < line.size && line[col] != '\n'
          return FileVarOrigin.new(File.expand_path(path), idx + 1, col + 1)
        end
        # Folded form (`key:` with the value on the next line): the first
        # non-blank character of that line.
        ((idx + 1)...lines.size).each do |value_idx|
          value_line = lines[value_idx]
          stripped = value_line.lstrip
          next if stripped.empty?
          return FileVarOrigin.new(File.expand_path(path), value_idx + 1, value_line.size - stripped.size + 1)
        end
        return nil
      end
      nil
    end
  end
end
