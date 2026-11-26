require "./executor"

module Krikri
  class TaskExecutor
    # Ansible's gather_facts action puts this key in the gather result
    # (`result['ansible_facts']['_ansible_facts_gathered'] = True`).
    # ansible-core's `_facts_gathered_for_host` gates `--gathering smart`
    # on it, and it is what lets one engine's fact cache warm the other's.
    # Present in the nested `ansible_facts` dict, absent from the
    # top-level fact vars (ansible's clean_facts -> strip_internal_keys).
    FACTS_GATHERED_MARKER = "_ansible_facts_gathered"

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
      # Under --gathering smart the pre-seeding in the constructor means
      # a host covered by a still-warm persisted fact cache already has
      # facts in @facts, so gathered_facts_for? excludes it here too -
      # that is what makes a warm rerun show `ok=0`/no banner for a
      # fully-cached host instead of always re-gathering. The cache is
      # READ for every gathering mode (see the constructor);
      # `implicit` still gathers over it, matching ansible-playbook.
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

      # The implicit task is queued before any other, so real's
      # dispatch-time `throttle:` conversion runs here first.
      validate_gather_throttle!(targets)

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
      unreachable_reported = Set(String).new
      targets.each do |host|
        next unless @unreachable_hosts.includes?(host.name)
        # Same wording/shape as report_unreachable's own banner - this
        # IS that host's unreachable report, just booked from the
        # Gathering Facts task instead of a later one, matching
        # Ansible's single-event recap for a host that never connects.
        # A transport failure discovered HERE carries this attempt's
        # own ssh error; a host the pre-upload pass already knew about
        # carries that pass's recorded one. A play-level
        # `ignore_unreachable:` reaches this implicit task too (real's
        # setup task inherits every play keyword), so the report is
        # booked ok+ignored and the host stays in the play (issue #1680).
        report_unreachable(nil, host, fresh_ssh_errors[host.name]? || @unreachable_ssh_errors[host.name]?, ignore: @play_ignore_unreachable)
        # An ignored unreachable never enters ansible's `_unreachable_hosts`,
        # so later tasks and plays must retry the connection rather than
        # repeat this result - drop the host from the run-scoped set the
        # pre-upload pass/this gather just filled.
        @unreachable_hosts.delete(host.name) if @play_ignore_unreachable
        # Remember every host this pass already reported: an ignored one
        # leaves the set above but still owes no separate ok/failed result.
        unreachable_reported << host.name
      end

      targets.each do |host|
        next if unreachable_reported.includes?(host.name)

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
          elsif (play_become_failure = gather_play_become_failure_message) && play_become_failure == error_message
            # The implicit task has no source position of its own, so real
            # prints the bare "Task failed." segment, then the keyword and
            # conversion links Origin'd at the play's become: value
            # (live-verified vs 2.21.6, issue #1497).
            origin = @play_become_origin.try { |source| ErrorBlock.origin_context(source[0], source[1], source[2]) }
            ErrorBlock.emit(ErrorBlock::Node.new("Task failed.")
              .with_chain(ErrorBlock::DIRECT_CAUSE, true,
                ErrorBlock::Node.new("Error processing keyword 'become'.", source_context: origin)
                  .with_chain(ErrorBlock::DIRECT_CAUSE, true,
                    ErrorBlock::Node.new("The value '#{@play_become_invalid}' could not be converted to 'bool'.", source_context: origin))))
            puts "fatal: [#{host.name}]: FAILED! => #{ResultDisplay.python_json_dump(JSON.parse({"changed" => false, "msg" => play_become_failure}.to_json))}".colorize(:red)
          elsif (keyword_failure = @facts_connection_keyword_failures[host.name]?) && keyword_failure.message == error_message
            # ansible's PlayContext post-validation failure: the implicit
            # task has no source position of its own, so the collapsed
            # chain prints "Task failed." bare, then the failing keyword
            # link Origin'd at the variable's defining site
            # (live-verified vs 2.21.6, issue #1419).
            ErrorBlock.emit(ErrorBlock::Node.new("Task failed.")
              .with_chain(ErrorBlock::DIRECT_CAUSE, true,
                ErrorBlock::Node.new("Error processing keyword '#{keyword_failure.keyword}': #{keyword_failure.conversion}",
                  source_context: keyword_failure.origin)))
            puts "fatal: [#{host.name}]: FAILED! => #{keyword_failure_message_json(keyword_failure)}".colorize(:red)
          elsif error_message && error_message.includes?(PluginManager::BECOME_METHOD_EMPTY)
            # The become-method failure dies in real's task executor
            # (become_loader's ValueError) before any module runs: the
            # [ERROR] block is the collapsed single "Task failed." segment
            # with NO Origin (the implicit task has no source position)
            # and the fatal carries {"changed": false, "msg": ...} exactly
            # like a regular task's (live-verified vs 2.19.11, issue #395).
            # Use #includes? instead of == to handle any minor formatting
            # differences in the error message while still detecting the
            # become method failure condition.
            ErrorBlock.emit(ErrorBlock::Node.new("Task failed.")
              .with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(PluginManager::BECOME_METHOD_EMPTY)))
            puts "fatal: [#{host.name}]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: #{PluginManager::BECOME_METHOD_EMPTY}\"}".colorize(:red)
          elsif error_message && connection_resolution_gather_message?(error_message)
            # Ansible's gather-time connection-resolution failure is a
            # plain one-line [ERROR] with no Origin and no cause chain,
            # then the standard fatal line (live-verified vs 2.19.11 for
            # an inventory-set ansible_connection, a play `connection:`
            # keyword and a leaked role default alike) - not the generic
            # "failed: / Error gathering facts:" pair.
            ErrorBlock.emit(ErrorBlock::Node.new(error_message))
            puts "fatal: [#{host.name}]: FAILED! => {\"changed\": false, \"msg\": \"#{error_message}\"}".colorize(:red)
          else
            puts "failed: [#{host.name}]".colorize(:red)
            puts "  Error gathering facts: #{error_message}".colorize(:red)
          end
          @results[host.name]["failed"] += 1
          # A failed implicit setup halts the host like any failed task -
          # ansible-playbook runs none of the play's tasks on it afterwards.
          book_failure_halt(host)
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

    # The failure message for a host whose effective ansible_connection
    # (the host's own var, a play's leaked role defaults, or the play's
    # `connection:` keyword - the same merged context the implicit gather
    # runs under) resolves to no connection plugin (see
    # PluginManager.connection_plugin_not_found?) or to a Python plugin
    # this engine cannot execute (connection_plugin_unsupported?), or nil
    # when the connection is one of this engine's own transports -
    # including "unset", which the executor's local/ssh default covers.
    private def connection_resolution_failure_message(host : Host, vars_context : Hash(String, JSON::Any)) : String?
      conn_type = vars_context["ansible_connection"]?.try(&.as_s?)
      return nil unless conn_type
      # The gather's own vars_context is the host's vars plus the play's
      # role layers, so it carries no `playbook_dir` magic var the way a
      # task's does: without the fallback the playbook-adjacent
      # `connection_plugins/` is never searched here and a plugin Ansible
      # resolves reads as "was not found" (issue #1658: a plugin in the
      # playbook's own connection_plugins/ must fail as unexecutable, not
      # as missing, before the first task ever runs).
      dir = PluginManager.playbook_dir_from(vars_context)
      dir = @playbook_dir if dir.nil? && @playbook_dir != "."
      return PluginManager.connection_plugin_execution_failure(conn_type) if PluginManager.connection_plugin_unsupported?(conn_type, dir)
      return nil unless PluginManager.connection_plugin_not_found?(conn_type, dir)

      "Task failed: the connection plugin '#{conn_type}' was not found"
    end

    # Whether *message* is the gather failure
    # connection_resolution_failure_message produced - either "Task failed:
    # the connection plugin 'X' was not found" or its cannot-be-executed
    # sibling. Both print in the one-line [ERROR] shape (no Origin, no
    # cause chain) Ansible's own gather-time resolution failure uses.
    private def connection_resolution_gather_message?(message : String) : Bool
      message.starts_with?("Task failed: the connection plugin '")
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
    #
    # An UNREACHABLE result is reported differently: ansible composes
    # that msg from the ssh transport's own error (report_unreachable
    # wraps the detail this returns), and the transport-unreachable wire
    # shape already carries it in stderr. A warm plugin-state cache
    # skips the upload-verification round trip, so a broken connection
    # first surfaces as interpret_remote_result's generic msg while
    # ssh's "Connection closed by ..." line sits in stderr - reporting
    # the generic msg verbatim hides the cause ansible shows (issue
    # #1659). Public as a spec seam.
    def self.facts_failure_message(result : JSON::Any) : String
      stderr = result["stderr"]?.try(&.as_s?)
      unreachable = result["unreachable"]?.try(&.as_bool?) == true
      if unreachable
        detail = stderr.try(&.strip)
        return detail unless detail.nil? || detail.empty?
      end
      msg = result["msg"]?.try(&.as_s) || "Unknown error"
      # The transport-unreachable shape carries the ssh stderr inside its
      # msg already (ansible's [ERROR] block shows just the Task failed
      # line there, no stderr section - issue #887's rejected-user
      # gather), so only module-level failures get the stderr dump.
      if stderr && !stderr.empty? && !unreachable
        msg += "\n  stderr: #{stderr.strip.lines[0, 10].join("\n  stderr: ")}"
      end
      msg
    end

    # The fatal message for the implicit Gathering Facts task when the
    # play's own become: is a literal boolean() refuses, or nil. Real
    # fails the inherited FieldAttribute conversion there like any task's
    # (see boolean_keyword_invalid_error); the value's Python repr is what
    # the message quotes.
    private def gather_play_become_failure_message : String?
      invalid = @play_become_invalid
      return nil unless invalid
      "Task failed: Error processing keyword 'become': The value '#{invalid}' could not be converted to 'bool'."
    end

    # The fatal message for a Gathering Facts task whose become is
    # enabled and whose `ansible_become_method` var resolves to
    # None/empty (see check_task_become_method's own comment for the
    # ansible mechanics, issue #395), or nil when the gather proceeds.
    # The become flag follows ansible's TaskExecutor._set_become_plugin
    # order: an `ansible_become` var (when set and convertible) wins,
    # otherwise the play's `become:` keyword. The method var is read
    # from the same three layers the implicit task's vars would carry
    # here - play-wide exported role vars (highest) > play vars >
    # inventory host vars.
    private def facts_become_method_failure(host : Host) : String?
      context = host.vars.dup
      @play_vars.each { |key, value| context[key] ||= value }
      @all_role_vars.each { |key, value| context[key] = value }

      substitutor = VarSubstitutor.new(vars: context, host_name: host.name)
      become = if raw = context["ansible_become"]?
                 decided = ansible_become_var_boolean(raw, substitutor)
                 decided.nil? ? @play_become : decided
               else
                 @play_become
               end
      return nil unless become

      raw = context["ansible_become_method"]?
      return nil unless ansible_var_truthy?(raw)
      return nil unless (method_raw = raw)

      rendered = render_task_var_value(method_raw, context, host.name)
      value = rendered.raw
      return nil unless value.nil? || (value.is_a?(String) && value.empty?)

      "Task failed: #{PluginManager::BECOME_METHOD_EMPTY}"
    end

    # The var layers the implicit gather task resolves its connection
    # keywords against, lowest precedence first: role defaults < inventory
    # host vars < play vars < vars_files < role vars < -e extra vars. That
    # is build_vars_context's ladder minus the block/task tiers and the
    # runtime ones (registered results, facts), none of which can exist
    # before the play's first task has run. Each layer's own defining
    # positions ride along so a failing keyword's Origin can point where
    # ansible points it (the variable's definition).
    private def gather_connection_var_layers(host : Host) : {Hash(String, JSON::Any), Hash(String, VarOrigin)}
      context = Hash(String, JSON::Any).new
      origins = Hash(String, VarOrigin).new
      merge_var_layer(context, origins, @all_role_defaults, @all_role_default_origins)
      merge_var_layer(context, origins, host.vars, host.var_origins)
      merge_var_layer(context, origins, @play_vars, @play_var_origins)
      # vars_files sit above play vars and below role vars; the implicit
      # gather task sees them too (live-verified vs 2.21.6: a vars_file's
      # `ansible_password: "{{ vault_missing }}"` fails Gathering Facts
      # with the Origin at the file's own line).
      unless @vars_files.empty?
        merge_var_layer(context, origins, load_vars_files(host), @vars_files_origins_cache[vars_files_cache_key(host)]?)
      end
      merge_var_layer(context, origins, @all_role_vars, @all_role_var_origins)
      merge_var_layer(context, origins, @extra_vars, @extra_var_origins)
      {context, origins}
    end

    # The connection-keyword failure that stops the implicit Gathering
    # Facts task, or nil. ansible post-validates PlayContext for the
    # implicit setup task exactly like a regular one, so a role's
    # exported `ansible_password: "{{ vault_ansible_password }}"` kills
    # the gather before any facts module runs (issue #1419,
    # jedimt.authorized_keys - ansible's fatal vs krikri's ok). See
    # check_task_connection_password for the regular-task path.
    private def gather_connection_password_failure(host : Host) : ConnectionKeywordError?
      context, origins = gather_connection_var_layers(host)
      key = connection_password_var_key(context)
      return nil unless key
      text = context[key]?.try(&.as_s?)
      return nil unless text && connection_password_template?(text)

      begin
        VarSubstitutor.new(vars: context, host_name: host.name).substitute(text, strict: true)
      rescue e : UndefinedVariableError
        return ConnectionKeywordError.new("password", e.message || "", var_origin_error_context(origins[key]?))
      end
      nil
    end

    # The fatal line's JSON payload for that failure, in ansible's own key
    # order (changed, msg) and Python json.dumps separators.
    private def keyword_failure_message_json(error : ConnectionKeywordError) : String
      ResultDisplay.python_json_dump(JSON.parse({
        "changed" => false,
        "msg"     => error.message,
      }.to_json))
    end

    private def gather_facts_for_host_measured(host : Host) : {Bool, String?, Bool}
      vars_context = Hash(String, JSON::Any).new
      host.vars.each { |key, value| vars_context[key] = value }

      # Role defaults are visible play-wide in Ansible - the play's static
      # roles are compiled (and their defaults merged into the play's var
      # stack) before ANY task runs, the implicit setup task included.
      # Lowest var layer: below the host's own inventory vars, above the
      # play's `connection:` keyword (vars always beat keywords).
      # vinealvees.general_configs (issue #811) lives entirely on this:
      # its defaults set `ansible_connection: network_cli` +
      # `ansible_network_os: ios`, Ansible's smart gather therefore
      # resolves the ios facts module over the network connection and
      # fails Gathering Facts fatally, while this engine's gather - which
      # used to see only the host's own vars - happily ssh'd out, booked
      # ok=1 and ran role tasks Ansible never reached.
      @all_role_defaults.each { |key, value| vars_context[key] ||= value }

      # The implicit setup task runs under the play's connection too: the
      # play-level `connection:` keyword fills in only where no
      # ansible_connection var (the host's own, here) already does -
      # Ansible's vars-vs-keyword rule keeps an inventory-set connection
      # var above the play keyword (live-verified vs 2.19). Without this
      # a play `connection: local` still ssh'd out just to gather facts
      # before its local tasks ever ran.
      if play_connection = @connection
        vars_context["ansible_connection"] ||= JSON::Any.new(play_connection)
      end

      # -e extra vars are ansible's highest-precedence var layer and apply
      # to the implicit setup task exactly like any other task, so
      # `-e ansible_connection=local` has to reach its connection
      # resolution too. Without them the gather kept the inventory's
      # connection (ssh, or an unsupported plugin) while every regular
      # task honored the override (live-verified vs 2.21.5, issue #1836).
      @extra_vars.each { |key, value| vars_context[key] = value }

      # The implicit setup task inherits the play's own become: keyword, and
      # real post-validates it on the PlayContext before resolving the
      # connection plugin, the become plugin or any connection keyword
      # (they all sit later in PlayContext's fattribute order) - an
      # unconvertible value therefore IS the gather's failure (issue
      # #1497).
      if play_become_failure_message = gather_play_become_failure_message
        return {false, play_become_failure_message, false}
      end

      # ansible post-validates the implicit setup task's PlayContext
      # BEFORE resolving its connection plugin, so a connection keyword
      # whose own value fails to render is the failure the gather reports
      # (issue #1419) - not the plugin resolution below.
      if keyword_failure = gather_connection_password_failure(host)
        @facts_connection_keyword_failures[host.name] = keyword_failure
        return {false, keyword_failure.message, false}
      end

      # Ansible resolves the connection plugin for the implicit setup
      # task too - an unresolvable ansible_connection fails Gathering
      # Facts with "the connection plugin 'X' was not found" instead of
      # attempting SSH (the silent fallback below reported a bogus
      # UNREACHABLE for what Ansible reports as a plain failure).
      if (conn_msg = connection_resolution_failure_message(host, vars_context))
        return {false, conn_msg, false}
      end

      # Real resolves the become plugin for the implicit setup task as
      # well (it is a real task carrying the play's become settings), and
      # a role's vars/main.yml is exported to every task in the play -
      # Gathering Facts included - at very high precedence. A role var
      # like `ansible_become_method: '{{ check.something if check is
      # defined else None }}'` therefore templates to None there and
      # fails the gather with "Task failed: A non-empty plugin name is
      # required." before any facts module runs (adarnimrod.
      # openbsd-bootstrap on ubuntu, issue #395: ansible's Gathering
      # Facts fatal vs krikri's ok).
      if (method_msg = facts_become_method_failure(host))
        return {false, method_msg, false}
      end

      # If this gathers over SSH the wire payload needs
      # ansible_connection=local, so decide that up front and serialize
      # once, instead of serializing, parsing and re-serializing just to
      # inject one key afterwards. The gather's context is this host's
      # own, so it resolves the connection from vars first: -e extra vars
      # outrank the inventory's ansible_connection there, exactly as
      # #local_connection? has to for the dispatch below.
      remote = PluginManager.remote_execution?("facts", host, vars_context, context_first: true)
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
      result = PluginManager.execute_plugin("facts", config.to_json, host, vars_context, false, nil,
        context_first: true)

      # The ssh transport's connection-level failure result carries ONLY the
      # unreachable flag (no "failed" key - it mirrors the shape real's own
      # fatal UNREACHABLE line prints). Gate on it too: a gather whose
      # dispatch never reached the target must book UNREACHABLE, not fall
      # through to the success path below and print `ok:` with no facts
      # while the play carries on (issue #887 - a role default
      # ansible_ssh_user the host rejects).
      if Krikri.result_failed_flag(result) || result["unreachable"]?.try(&.as_bool?) == true
        msg = TaskExecutor.facts_failure_message(result)
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
        # The gatherer's discovery warnings ride the result under an
        # internal marker - real's are controller-side Display warnings,
        # never result keys, printed on stderr while the first module
        # executes. Emit them here (the implicit gather's own display
        # point) and strip the marker before the result is stored or
        # registered anywhere.
        result["_ansible_discovery_warning"]?.try(&.as_a?).try &.each do |warning|
          ResultDisplay.emit_display_warning(warning.as_s? || warning.to_s)
        end
        result.as_h?.try(&.delete("_ansible_discovery_warning"))
        @facts_results[host.name] = result
        # A later successful gather clears any stale interpreter-failure
        # stamp, so the report below never prints for a host whose facts
        # eventually came through.
        @facts_interpreter_missing.delete(host.name)
        @facts_connection_keyword_failures.delete(host.name)
        facts = Hash(String, JSON::Any).new
        ansible_facts.as_h.each { |key, value| facts[key] = value }
        # The gather_facts action's own marker (see its comment above),
        # so a persisted cache entry - of either backend - tells a later
        # run of either engine that this host's facts are gathered.
        facts[FACTS_GATHERED_MARKER] = JSON::Any.new(true)
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
        # Ansible persists every gather into the configured cache plugin,
        # not just the ones `smart` could later skip - a run with the
        # default implicit gathering still leaves the next run a warm
        # cache (live-verified vs 2.21.6). It also MERGES a re-gather
        # into whatever the entry already held (VariableManager's
        # set_host_facts does `host_cache |= facts`), so a gather_subset
        # run grows the cache rather than shrinking it.
        persisted = Hash(String, JSON::Any).new
        if cached = FactCache.read(host.name)
          cached.each { |key, value| persisted[key] = value }
        end
        facts.each { |key, value| persisted[key] = value }
        # `ansible_python_interpreter` is a flat connection var Ansible
        # resolves per run, never a cached fact - and a warm entry that
        # carries it makes every later ansible run that seeds from the cache
        # warn "Removed restricted key from module data:
        # ansible_python_interpreter" (clean_facts strips
        # `ansible_.*_interpreter`). The live capture of 2.21.6's own cache
        # has no such key.
        persisted.delete("ansible_python_interpreter")
        FactCache.write(host.name, persisted)
      end

      {true, nil, false}
    rescue ex
      {false, ex.message, false}
    end

    # Whether *host* has gathered facts this run - ansible-core's
    # `_facts_gathered_for_host` (vars/manager.py), which reads
    # `facts.get('_ansible_facts_gathered', False)` off the host's fact
    # cache entry and gates `--gathering smart` on exactly that. So the
    # marker, not "any fact exists", is the question:
    #
    #   * an in-run implicit gather (or an earlier play's) writes the
    #     marker into @facts, so a later play skips, cache or no cache;
    #   * a warm cache entry written by ansible-playbook carries it, so
    #     that host is skipped;
    #   * a set_fact alone, or an explicit `setup:` task, does NOT set it
    #     (the gather action does, a bare setup module result does not),
    #     so the next play under smart gathers - live-verified against
    #     ansible-core 2.21.6 with no cache configured: play 1 `setup:`,
    #     then play 2's implicit gather under `gathering: smart`, still
    #     runs there.
    private def gathered_facts_for?(host : Host) : Bool
      facts = @facts[host.name]?
      return false unless facts
      # A `set_fact: _ansible_facts_gathered: true` lands in @facts at the
      # high tier but never enters ansible's fact cache, which is all
      # `_facts_gathered_for_host` reads - so it must not satisfy the gate.
      return false if @set_facts[host.name]?.try(&.has_key?(FACTS_GATHERED_MARKER))
      facts[FACTS_GATHERED_MARKER]?.try(&.as_bool?) == true
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

      # Ansible's gather_facts ACTION - a task-level `gather_facts:`, as
      # opposed to the `setup:` module - stamps the marker onto its own
      # result, and `--gathering smart` then honours it: live-verified vs
      # 2.21.6, play 1 `gather_facts:` task + play 2 implicit gather under
      # smart = no second gather, while the same playbook with `setup:`
      # gathers again. Written into the shared result hash so a
      # `register:`ed result carries it exactly as ansible's does.
      if !high_precedence && task && task.module_name.split(".").last == "gather_facts"
        facts_hash[FACTS_GATHERED_MARKER] = JSON::Any.new(true)
      end

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
        # A set_fact: write also retires the name from the
        # INJECT_FACTS_AS_VARS deprecation - real's SET_FACT layer is
        # untagged and outranks the injected copy, so the name warns no
        # more (see VarSubstitutor.set_fact_var_name?).
        VarSubstitutor.add_set_fact_var_name(host.name, key) if high_precedence
      end
      @facts_dict_cache.delete(host.name)
      @hv_generation += 1
    end

    # Real (2.19, live-verified) prints, on stderr immediately before the
    # set_fact task's ok: line, the same reserved-name warning the
    # vars:-key path emits - "[WARNING]: Found variable using reserved
    # name '<key>'." plus the key's own Origin block and a blank line -
    # once per key position per run (Display.warning's dedup). The Origin
    # scan is ResultDisplay.mapping_key_origin's; merge_ansible_facts
    # runs inside concurrent per-host fibers, so the dedup set needs the
    # mutex like playbook_parser.cr's @@reserved_toplevel_var_warnings.
    @@reserved_set_fact_warnings = Set(String).new
    RESERVED_SET_FACT_WARN_MUTEX = Mutex.new

    private def warn_reserved_set_fact_key(task : Task, key : String) : Nil
      return unless PlaybookParser::RESERVED_VAR_NAMES.includes?(key)
      return unless origin = ResultDisplay.mapping_key_origin(task, key)
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
    # ResultDisplay's mapping_key_origin (quoted keys carry their colon
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
