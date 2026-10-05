require "./executor"
require "../needle_lookup"
require "../unsafe_values"
require "krikri-jinja/krikri_jinja"
require "../jinja_host_context"
require "../plugin_helpers/ansible_splitlines"

module Krikri
  class TaskExecutor
    private def notify_hosts_if_changed(task : Task, hosts : Array(Host), changed_before : Hash(String, Int32)) : Nil
      notify_list = task.notify
      return if notify_list.nil? || notify_list.empty?

      hosts.each do |host|
        next unless @results[host.name]["changed"] > changed_before[host.name]
        notify_handlers(task, host, notify_list)
      end
    end

    # Multi-host counterpart to execute_include_tasks (the no-loop case
    # only - see task_has_loop?): resolves when:/the included file's path
    # PER HOST first (cheap - local template substitution, no remote
    # I/O), groups hosts that end up resolving the SAME file together,
    # then runs each group's included tasks via run_task_batch instead of
    # execute_include_tasks's single-host run_task_list. Real-world
    # include_tasks: almost always resolves identically for every host in
    # a homogeneous play (e.g. `include_tasks: setup-{{ ansible_os_family
    # }}.yml` across an all-Debian inventory - exactly what geerlingguy.
    # containerd/geerlingguy.kubernetes do), so this virtually always
    # collapses to one group holding every host - the case that actually
    # mattered for the ~1.8x cold-run slowdown this was written to fix.
    private def load_vars_files(host : Host) : Hash(String, JSON::Any)
      # Keyed on the hostvars generation, not just the host: this runs
      # for "Gathering Facts" too, BEFORE any fact exists, and a path
      # templated against a fact (`vars-{{ ansible_os_family }}.yml`)
      # resolves to nothing at that point. Caching that empty result per
      # host would poison every later task.
      cache_key = "#{host.name}\u0000#{@hv_generation}"
      if cached = @vars_files_cache[cache_key]?
        return cached
      end

      merged = Hash(String, JSON::Any).new
      base = base_context_a_for(host).dup
      base_context_b_for(host).each { |key, value| base[key] = value }
      # vars_files paths are play/task-arg-grade templating, not loop-
      # source resolution - Ansible's legacy-alias synthesis applies
      # here (see #synthesize_legacy_ssh_aliases).
      synthesize_legacy_ssh_aliases(base)
      substitutor = VarSubstitutor.new(vars: base, host_name: host.name)

      @vars_files.each do |candidates|
        candidates.each do |raw|
          rendered = (substitutor.substitute(raw) rescue raw)
          path = File.expand_path(rendered, @vars_files_dir)
          next unless File.exists?(path)

          begin
            text = File.read(path)
            UnsafeValues.mark_yaml_text(text)
            parsed = YAML.parse(text)
            if hash = parsed.as_h?
              hash.each { |key, value| merged[key.to_s] = JSON.parse(value.to_json) }
            end
          rescue
            # A vars file that will not parse is skipped rather than
            # taking the run down - ansible-playbook likewise does
            # not abort for a vars_files entry it cannot use (verified:
            # a MISSING file is tolerated silently, rc=0).
          end
          break
        end
      end

      @vars_files_cache[cache_key] = merged
      # Only a host's CURRENT generation entry is ever looked up (the key
      # embeds the generation, which only ever increases), so older
      # entries for this host are unreachable garbage. Every register:/
      # fact write bumps the generation - without this sweep the cache
      # grows one full vars_files set per bump for the whole run. Other
      # hosts' latest entries are kept; they still serve if their own
      # generation hasn't moved.
      prefix = "#{host.name}\u0000"
      @vars_files_cache.keys.each do |key|
        @vars_files_cache.delete(key) if key.starts_with?(prefix) && key != cache_key
      end
      merged
    end

    private def first_existing(roots : Array(String), candidate : String) : String?
      roots.each do |root|
        path = File.join(root, candidate)
        return path if File.exists?(path)
      end
      nil
    end

    # include_vars: reads a YAML file from the CONTROLLER and merges it
    # into this host's variable context - nothing runs on the target, so
    # it is a pseudo-module here rather than a plugin binary (same shape
    # as meta:).
    #
    # With `name:`, the whole file is loaded as a single dict under that
    # name (`os_vars`), which is how roles stage OS-specific values before
    # applying them selectively; without it the file's keys are merged
    # individually.
    private def execute_validate_argument_spec(task : Task, host : Host) : Nil
      vars_context = build_vars_context(task, host)
      options = task.validate_argument_spec_options || Hash(String, JSON::Any).new
      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

      errors = [] of String
      missing_required = [] of String
      type_errors = [] of String
      options.each do |option_name, spec|
        # Ansible templates the ENTIRE argument spec - `default:`
        # expressions included - when finalizing the
        # validate_argument_spec call's own args, BEFORE ever looking at
        # whether the option itself was provided (live-verified against
        # 2.19.4: lablabs.rke2's `default: "{{ groups[rke2_servers_
        # group_name] }}"` fails the task with "Error while resolving
        # value for 'argument_spec': object of type 'dict' has no
        # attribute 'masters'" even with the option passed on the command
        # line). So a default whose own lookup fails fails THIS task,
        # regardless of the option's presence - this engine used to
        # resolve it leniently to undefined, pass the task, and only
        # fail three tasks later at a `when:` on the same expression.
        resolved_default = nil
        if (default = spec["default"]?) && (raw_default = default.raw).is_a?(String) && raw_default.includes?("{{")
          begin
            # The strict substitute only reaches bare refs and simple
            # chains - argument-spec defaults are arbitrary compound
            # expressions (rke2's `'server' if inventory_hostname in
            # groups[rke2_servers_group_name] else ...` ternary), so run
            # the dict-miss/undefined-ref scan over the whole expression
            # as well.
            substitutor.scan_strict_expression_refs(raw_default)
            rendered = substitutor.substitute(raw_default, strict: true)
            resolved_default = Krikri.parse_json_or_python_literal(rendered)
          rescue ex : UndefinedVariableError
            errors << "Error while resolving value for 'argument_spec': #{ex.message}"
            next
          end
        elsif default = spec["default"]?
          resolved_default = default
        end

        value = vars_context[option_name]?

        if value.nil?
          # Ansible applies spec defaults with set_default=False
          # before check_required_arguments (ansible-core's
          # the Ansible module _set_defaults), so only a
          # default whose value is not None stands in for a missing
          # option - a spec declaring `default: null` alongside
          # `required: true` does NOT satisfy the requirement
          # (robertdebock.vault_agent's vault_agent_address, round 979000:
          # ansible-playbook fails the synthesized validation task
          # with "missing required arguments: vault_agent_address" while
          # this engine treated the null default as a provided value,
          # passed validation, and only failed the role's own
          # assert-fallback tasks later with a generic assertion error).
          if resolved_default && !resolved_default.raw.nil?
            value = resolved_default
          else
            # A var provided as an explicit null (`vault_agent_address:`)
            # counts as provided in Ansible - the action plugin picks
            # up any name present in task_vars and check_required_arguments
            # only flags names ABSENT from the parameters dict - so only a
            # var the play never defines can be "missing required" here
            # (vars_context[option_name]? is nil only in that case; a
            # provided-as-null value surfaces as a JSON::Any wrapping nil
            # and falls through to the type check, which skips nulls).
            missing_required << option_name if spec["required"]?.try(&.as_bool?) == true
            next
          end
        end

        if declared_type = spec["type"]?.try(&.as_s?)
          # A null value (the role default is the YAML literal `null` -
          # grzegorzfranus.github_runner's `github_runner_user_uid: null`
          # with `type: int`) is Ansible's "not provided": the
          # validator skips type conversion for None entirely ("if value
          # is None: continue") - it never says "of type str and we were
          # unable to convert to int" against a None.
          unless value.raw.nil?
            unless argument_type_matches?(value, declared_type)
              # Kept separate from `errors` so the combined missing-
              # required message (emitted after the loop) can precede
              # every type error the way Ansible's validator orders
              # them (check_required_arguments before
              # _validate_argument_types).
              type_errors << "argument '#{option_name}' is of type #{json_type_name(value)} and we were unable to convert to #{declared_type}"
            end
          end
        end
      end

      # Real check_required_arguments raises ONE combined message
      # ("missing required arguments: %s" % ", ".join(sorted(missing)))
      # listing every missing option sorted by name - not one error per
      # option in declaration order (which this engine used to emit, in
      # the singular form, one entry at a time).
      errors << "missing required arguments: #{missing_required.sort.join(", ")}" unless missing_required.empty?
      errors.concat(type_errors)

      result = if errors.empty?
                 # Ansible's passing action result carries
                 # {"changed": false, "msg": "The arg spec validation
                 # passed"} but its stdout callback prints a bare
                 # `ok: [host]` - ResultDisplay would surface the msg as
                 # an extra detail line under the ok status, so the
                 # display-visible result omits it (nothing registers
                 # this synthesized task, so nothing else could read it).
                 JSON::Any.new({
                   "changed" => JSON::Any.new(false),
                 } of String => JSON::Any)
               else
                 JSON::Any.new({
                   "changed"         => JSON::Any.new(false),
                   "failed"          => JSON::Any.new(true),
                   "msg"             => JSON::Any.new("Validation of arguments failed:\n#{errors.join("\n")}"),
                   "argument_errors" => JSON::Any.new(errors.map { |e| JSON::Any.new(e) }),
                 } of String => JSON::Any)
               end

      # Display/stats flow through the same pipeline as every other task
      # result so a failed validation shows Ansible's one-line
      # `fatal: [host]: FAILED! => {json}` dump (argument_errors included)
      # instead of the old multi-line `failed:`/`Message:` shape, and
      # ignore_errors: stats semantics (ok+ignored, not failed) stay
      # identical to the rest of the engine.
      ignore_errors = resolve_task_ignore_errors(task)
      ResultDisplay.display_result(host, result, @diff_mode, ignore_errors: ignore_errors, module_name: task.module_name, source_task: task)
      ResultDisplay.update_stats(@results[host.name], result, ignore_errors)
      @halted_hosts.add(host.name) if !errors.empty? && !ignore_errors
    end

    # Whether *value* is compatible with a declared argument_specs.yml
    # `type:`. Lenient by design (matching ansible-core's own AnsibleModule
    # type coercion, which accepts a numeric string for `int`, a single
    # scalar promoted to a one-element list for `list`, etc.) - this only
    # flags a value that's unambiguously the wrong shape (a Hash/Array
    # where a scalar was declared, or vice versa), not every case real
    # Ansible's coercion would technically also accept.
    private def argument_type_matches?(value : JSON::Any, declared_type : String) : Bool
      case declared_type
      when "list"
        true # a bare scalar is promoted to a one-element list; always compatible
      when "dict"
        value.raw.is_a?(Hash)
      when "bool"
        !value.raw.is_a?(Hash) && !value.raw.is_a?(Array)
      when "int", "float"
        case value.raw
        when Int64, Int32, Float64 then true
        when String                then value.as_s.to_f64? != nil
          # Python's bool is a subclass of int (isinstance(True, int) is
          # True) - ansible-core's own argument-spec validator
          # accepts a bool value for a declared int/float param on that
          # basis. dev-sec mysql_hardening's own argument_specs.yml
          # declares mysql_hardening_skip_show_database as `type: int,
          # default: 1` while defaults/main.yml sets it to the literal
          # boolean `true` - a real (if sloppy) mismatch in the role
          # itself that ansible-playbook tolerates via this exact
          # coercion; rejecting it here failed the role's own argument-
          # spec validation task before any hardening logic ever ran.
        when Bool then true
        else           false
        end
      when "path", "str", "raw"
        true # ansible-core stringifies almost anything for these
      else
        true # an unrecognized declared type (jsonarg, etc.) - don't guess
      end
    end

    # Resolve with_fileglob patterns (if any) against the control host's
    # filesystem, after substituting any {{ vars }} in the pattern.
    private def expression_evaluator_for(vars_context : Hash(String, JSON::Any)) : VariableSubstitutor::ExpressionEvaluator
      VariableSubstitutor::ExpressionEvaluator.new(vars_context)
    end

    private def json_type_name(value : JSON::Any) : String
      case value.raw
      when Hash         then "dict"
      when Array        then "list"
      when Bool         then "bool"
      when Int64, Int32 then "int"
      when Float64      then "float"
      else                   "str"
      end
    end

    # Python's own type name for a resolved loop-source value, matching
    # Ansible's own error wording exactly ("not 'NoneType'", "not
    # 'str'"). Only 'NoneType' and 'str' were live-verified (round174
    # matrix scenarios 11a/11c); 'int'/'float'/'bool'/'dict' are inferred
    # from the same CPython type()/__name__ convention, not independently
    # verified against a ansible-playbook run.
    private def python_type_name(value : JSON::Any) : String
      case value.raw
      when Nil     then "NoneType"
      when Bool    then "bool"
      when Int64   then "int"
      when Float64 then "float"
      when Hash    then "dict"
      when Array   then "list"
      else              "str"
      end
    end

    # Parse *result* (the string output of evaluating a loop template) into a
    # list of JSON items. The evaluator stringifies, so an already-JSON
    # encoded list comes back as JSON text and is parsed back here; any other
    # emissions are treated as unresolvable (nil), matching a nil lookup.
    private def parse_list_result(result : String, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      return nil if result.empty?
      text = result.strip
      parsed = JSON.parse(text) rescue nil
      return nil unless parsed
      parsed.as_a?
    end

    # with_subelements(list, key): resolve the *list* template (usually a
    # registered `{{ var.results }}`) to a list of dicts, then yield
    # [parent_dict, subelement] pairs for each element of each dict's `key`
    # sub-list. Returns nil when the task has no with_subelements source.
    private def register_skip_result(task : Task, host : Host) : Nil
      register_name = task.register
      return if register_name.nil? || register_name.empty?

      # false_condition: the when: expression that evaluated False (the bare
      # literal `false` stays a bool, like YAML gives real).
      #
      # Key order is Ansible's own (task_executor.py builds
      # `dict(changed=False, skipped=True,
      # skip_reason='Conditional result was False') | result_context`,
      # the conditional's false_condition landing last): a later
      # `to_json` of a skipped register - or a loop over a registered
      # loop's `results` - renders it verbatim.
      condition = @last_false_condition
      false_condition = condition == "false" ? JSON::Any.new(false) : JSON::Any.new(condition || "")
      register_result(host, register_name, JSON::Any.new({
        "changed"         => JSON::Any.new(false),
        "skipped"         => JSON::Any.new(true),
        "skip_reason"     => JSON::Any.new("Conditional result was False"),
        "false_condition" => false_condition,
      } of String => JSON::Any))
    end

    # Reports a when:-skipped batch member: the print and skipped counter
    # were deferred by execute_batch_group (defer_display/defer_stats) so
    # the group's skips don't all appear during batch-build; this emits
    # them here, as execute_task consumes each member in task order. Mirrors
    # what when_passes? does for the solo path.
    private def ensure_grouped(tasks : Array(Task)) : Nil
      return unless @batching_enabled

      key = tasks.object_id
      return if @grouped_lists.includes?(key)
      @grouped_lists << key

      TaskBatcher.plan(tasks, ->certainly_aborts_on_notify?(Task)).each do |group|
        next if group.size < 2
        group.each { |member| @task_group[member] = group }
      end
    end

    # Entry point called from execute_task for the plain (non-looped,
    # non-until:, non-async:) execution path. Returns {false, nil} if
    # batching doesn't apply to this task/host at all (not part of a
    # group, a delegate_to: divergence, or a local connection) - the
    # caller falls through to the normal execute_task_once path in that
    # case, completely unaffected. Returns {true, result} if it does -
    # result is nil only when this specific task's own when: was false
    # (already fully handled: printed, counted, cached), exactly matching
    # what execute_task_once returns for a skipped task.
    private def execute_group_by(params : Hash(String, String), host : Host) : JSON::Any
      key = params["key"]?
      if key.nil?
        # Real group_by.py returns a failed RESULT for a missing key (no
        # raise): the fatal dump's msg stays bare while the [ERROR] chain
        # wraps it as "Task failed: Action failed: <msg>" - the same
        # shape include_vars's own failed results render through (see
        # ResultDisplay's _ansible_action_level + _ansible_error_detail
        # handling).
        failure = {
          "changed"               => JSON::Any.new(false),
          "failed"                => JSON::Any.new(true),
          "msg"                   => JSON::Any.new("the 'key' param is required when using group_by"),
          "_ansible_action_level" => JSON::Any.new(true),
          "_ansible_error_detail" => JSON::Any.new("Action failed: the 'key' param is required when using group_by"),
        } of String => JSON::Any
        Krikri.mark_failed_key_order(JSON::Any.new(failure), FAILED_KEY_ORDER_DEFAULT)
        return JSON.parse(failure.to_json)
      end

      inventory = @inventory
      unless inventory
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "group_by: no inventory available in this context"}.to_json)
      end

      # Ansible's group_by action crashes on non-string YAML literal args
      # (the parser marks those; see NON_STRING_PARAM_PREFIX) while
      # building its result dict: key hits `group_name.replace(' ', '-')`
      # - "'<type>' object has no attribute 'replace'" - and parents, a
      # non-list/non-string, hits the
      # `[name.replace(' ', '-') for name in parent_groups]` comprehension
      # - "'<type>' object is not iterable". Falsy literals crash too
      # (args.get returns the value whenever the key is present), a None
      # key (`key:` with no value - the parser wires literal nulls as
      # NONE_SENTINEL - included); the key crash precedes the parents
      # crash (add_group is assigned first).
      if key == Krikri::NONE_SENTINEL
        return literal_crash_result("'NoneType' object has no attribute 'replace'")
      end
      if native = Krikri.non_string_scalar(key)
        return literal_attribute_crash_result(native, "replace")
      end
      if parents_raw = params["parents"]?
        if parents_raw == Krikri::NONE_SENTINEL
          return literal_crash_result("'NoneType' object is not iterable")
        end
        if native = Krikri.non_string_scalar(parents_raw)
          return literal_crash_result("'#{Krikri.python_scalar_type_name(native)}' object is not iterable")
        end
        # A LIST parents arg whose MEMBERS aren't all strings crashes the
        # same comprehension at the first non-string member - see
        # list_member_attribute_crash. (The key-"" inventory abort comes
        # only after this: real builds the whole result dict before the
        # executor's add_group processing touches the inventory.)
        if bare = list_member_attribute_crash(parents_raw, "replace")
          return literal_crash_result(bare)
        end
      end

      # An empty-string key passes the action's checks and aborts the
      # whole run in the executor's add_group processing - Ansible's
      # inventory layer, rc 1, no recap, no further output (same stage
      # and shape as add_host's empty-name abort below).
      if key.empty?
        STDERR.puts "[ERROR]: Invalid empty/false group name provided:".colorize(:red)
        STDOUT.flush
        STDERR.flush
        Process.exit(1)
      end

      # Ansible's group_by.py: the key is ONE group name (spaces become `-`,
      # never split on commas) and parents defaults to ["all"]; its
      # result is exactly {changed, add_group, parent_groups} (the strategy
      # then flips changed to true when the group or host membership is
      # new). The registered result carries no msg/groups keys.
      group_name = key.gsub(' ', '-')
      explicit_parents = params["parents"]?.try(&.split(",").map(&.strip).reject(&.empty?))
      parent_names = (explicit_parents || ["all"]).map(&.gsub(' ', '-'))

      changed = false
      group = inventory.get_or_create_group(group_name)
      unless group.hosts.has_key?(host.name)
        group.add_host(host)
        changed = true
      end
      explicit_parents.try &.each { |parent_name| inventory.get_or_create_group(parent_name.gsub(' ', '-')).add_child(group_name) }

      JSON.parse({"changed" => changed, "add_group" => group_name, "parent_groups" => parent_names, "failed" => false}.to_json)
    end

    # set_stats: - same "no uploaded plugin binary" category as
    # group_by:/reboot: above. Writes into CustomStats (a process-wide
    # accumulator, not scoped to this TaskExecutor instance - real
    # Ansible's own custom-stats block covers the WHOLE run, and
    # krikri-playbook.cr constructs a fresh TaskExecutor per play).
    private def execute_reboot(params : Hash(String, String), exec_host : Host, vars_context : Hash(String, JSON::Any),
                               check_mode : Bool = @check_mode) : JSON::Any
      # Ansible's reboot module always returns an "elapsed" field (integer
      # seconds since the reboot command was issued) in its result, including in
      # check mode where it returns {'changed': True, 'elapsed': 0,
      # 'rebooted': True} - round900541 derjd.reboot: the role's reboot:
      # handler registers its result as rv and a follow-up debug: task reads
      # rv.elapsed, which crashed this engine with "object of type 'dict' has
      # no attribute 'elapsed'" where Ansible succeeded.
      return JSON.parse({"changed" => true, "elapsed" => 0, "failed" => false, "msg" => "Would have rebooted"}.to_json) if check_mode

      if PluginManager.local_connection?(exec_host, vars_context)
        return JSON.parse({
          "changed" => false,
          "elapsed" => 0,
          "failed"  => true,
          "msg"     => "ansible.builtin.reboot is not supported over a local connection (would reboot the controller itself)",
        }.to_json)
      end

      reboot_timeout = params["reboot_timeout"]?.try(&.to_i?) || 600
      connect_timeout = params["connect_timeout"]?.try(&.to_i?) || 5
      pre_reboot_delay = params["pre_reboot_delay"]?.try(&.to_i?) || 2
      post_reboot_delay = params["post_reboot_delay"]?.try(&.to_i?) || 0
      # A None test/reboot command (YAML `test_command:` with no value -
      # the parser wires literal nulls as NONE_SENTINEL - or a whole-span
      # null template) falls back to Ansible's argspec defaults, same as an
      # empty string always did.
      test_command = params["test_command"]?.try { |v| v == Krikri::NONE_SENTINEL || v.empty? ? nil : v } || "whoami"
      reboot_command = params["reboot_command"]?.try { |v| v == Krikri::NONE_SENTINEL || v.empty? ? nil : v } || "systemctl reboot"

      connection_host = PluginManager.get_connection_host(exec_host, vars_context)
      user = exec_host.user || "root"
      identity_file = vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)

      sleep pre_reboot_delay.seconds if pre_reboot_delay > 0

      # A reboot command genuinely killing its own SSH session mid-
      # response (rc 255, broken pipe, etc.) is the EXPECTED successful
      # outcome here, not an error - only a clean non-zero exit from the
      # remote shell itself (the command was rejected outright, e.g.
      # permission denied) is worth surfacing.
      issue_result = SSHManager.exec(connection_host, user, "(sleep 1; #{reboot_command}) &", exec_host.port, timeout: 15, identity_file: identity_file) rescue nil
      # Ansible stamps its elapsed clock the moment the shutdown command
      # returns (result['start'] in the action plugin) and reports elapsed as
      # integer seconds on EVERY path after that point - including when the
      # wait itself times out - so a registered rv.elapsed is always readable.
      reboot_started_at = Time.instant
      if issue_result && issue_result[:exit_code] != 0 && issue_result[:exit_code] != 255 && !issue_result[:stderr].empty?
        return JSON.parse({
          "changed" => false,
          "elapsed" => 0,
          "failed"  => true,
          "msg"     => "Failed to issue reboot command: #{issue_result[:stderr]}",
        }.to_json)
      end

      # Give the box a moment to actually start going down before
      # polling for it to come back - polling immediately risks a false
      # "success" against the OLD, not-yet-dead SSH session/ControlMaster.
      sleep 5.seconds

      deadline = Time.instant + reboot_timeout.seconds
      reconnected = false
      until Time.instant >= deadline
        result = SSHManager.exec(connection_host, user, test_command, exec_host.port, timeout: connect_timeout, identity_file: identity_file) rescue nil
        if result && result[:exit_code] == 0
          reconnected = true
          break
        end
        sleep Math.min(connect_timeout, 5).seconds
      end

      unless reconnected
        return JSON.parse({
          "changed" => false,
          "elapsed" => (Time.instant - reboot_started_at).total_seconds.to_i,
          "failed"  => true,
          "msg"     => "Timed out waiting for #{connection_host} to come back after reboot (#{reboot_timeout}s)",
        }.to_json)
      end

      sleep post_reboot_delay.seconds if post_reboot_delay > 0

      # post_reboot_delay sits inside Ansible's elapsed window too (its
      # action plugin sleeps before validating the reboot, both after start).
      elapsed_seconds = (Time.instant - reboot_started_at).total_seconds.to_i

      JSON.parse({
        "changed"  => true,
        "elapsed"  => elapsed_seconds,
        "failed"   => false,
        "rebooted" => true,
        "msg"      => "Reboot complete",
      }.to_json)
    end

    # Whether *result* is a connection-level (SSH transport) failure
    # rather than a remote module failure - PluginManager's
    # `interpret_remote_result` stamps `unreachable: true` on exactly
    # those (see SSHManager.connection_level_failure? for what
    # qualifies), and nothing else ever sets that key on a task result.
    private def unreachable_task_result?(result : JSON::Any) : Bool
      result.as_h?.try(&.["unreachable"]?.try(&.as_bool?)) == true
    end

    # Override a task's own changed/failed verdict with changed_when:/
    # failed_when:, evaluated against vars_context plus the task's own result
    # (made available under its own register: name, mirroring Ansible -
    # a bare literal like "false" needs no register: at all; referencing a
    # result field like "result.rc" does). Same substitute-then-evaluate
    # pipeline as when_condition/until_condition.
    private def finish_single_task(task : Task, host : Host, result : JSON::Any, fact_host : Host = host,
                                   vars_context : Hash(String, JSON::Any)? = nil, exec_host : Host? = nil) : Nil
      result = debug_if_requested(task, host, result)
      merge_ansible_facts(fact_host, result, task.module_name.ends_with?("set_fact"))

      if register_name = task.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      # An SSH-transport-level failure (the result's own `unreachable`
      # marker, set by PluginManager.interpret_remote_result when the
      # stderr names ssh itself) is Ansible's UNREACHABLE, not a
      # failed task: book it the way the pre-run unreachable pass's
      # results are booked and remove the host from the rest of the run.
      # Without this, a host that dies mid-play (reboot that never came
      # back, network gone) kept running every later task and each one
      # was booked as a generic "Plugin execution failed on remote"
      # failed - found via robertdebock.common's warm rerun against a
      # host the cold run's reboot had killed: ansible-playbook
      # recap'd `unreachable=1 failed=0` and halted the host at
      # Gathering Facts, this engine booked `failed=2` and ran on.
      if unreachable_task_result?(result)
        report_unreachable(task, host, result["stderr"]?.try(&.as_s?), no_log: resolve_task_no_log(task, vars_context))
        # Only a host whose unreachability is FATAL (not
        # ignore_unreachable:'d away) is remembered: an ignored
        # unreachable keeps being retried per task, exactly like real
        # Ansible, so it must not be pinned into the never-retry set.
        @unreachable_hosts << host.name unless task.ignore_unreachable?
        return
      end

      # A plugin can voluntarily report itself skipped via a "skipped"
      # key in its own result JSON (currently only debug.cr's own
      # verbosity: gate: `verbosity: 2` with a run below that level).
      # PluginResult has no real `skipped` FIELD - the plugin's own
      # `skipped: true` kwarg just lands in its generic `@extra` bag
      # and gets serialized as an ordinary top-level JSON key - but
      # nothing downstream of THIS point ever checked for it: since
      # changed/failed both stay false, it fell straight into the
      # normal "ok" display/stats path, with the plugin's own literal
      # msg text ("skipped") printed as if it were real debug output,
      # and counted as `ok=`, never `skipped=`. Found benchmarking
      # evrardjp.keepalived's own `debug: var: keepalived_scripts
      # verbosity: 2` tasks (a standard verbosity-gated debug idiom) -
      # Ansible correctly shows these as `skipping:` and counts
      # them under `skipped=`, not `ok=`.
      if result["skipped"]?.try(&.as_bool) == true
        puts "skipping: [#{host.name}]#{Krikri::ResultDisplay.skip_result_suffix(result)}".colorize(:cyan)
        @results[host.name]["skipped"] += 1
        return
      end

      changed = result["changed"]?.try(&.as_bool) || false
      failed = Krikri.result_failed_flag(result)
      if changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      ignore_errors = resolve_task_ignore_errors(task, vars_context)
      no_log = resolve_task_no_log(task, vars_context)
      if @adhoc
        ResultDisplay.display_adhoc_result(host, result, @diff_mode, module_name: task.module_name)
      else
        ResultDisplay.display_result(host, result, @diff_mode, ignore_errors: ignore_errors, no_log: no_log, module_name: task.module_name, delegate_target: exec_host && exec_host != host ? exec_host.name : nil, source_task: task)
      end
      ResultDisplay.update_stats(@results[host.name], result, ignore_errors)
      halt_if_failed(task, host, failed, result)
    end

    # Marks `host` as halted (no further tasks in this play run for it)
    # when `failed` and the task didn't opt out via ignore_errors:.
    private def print_skipped_tasks(tasks : Array(Task), host : Host) : Nil
      tasks.each do |nested_task|
        # A nested block is transparent - like Ansible, it gets no
        # "TASK [...]" banner of its own, only its members do.
        if nested_task.block?
          print_skipped_tasks(nested_task.block_tasks || [] of Task, host)
          print_skipped_tasks(nested_task.always_tasks || [] of Task, host)
          next
        end

        connection_host = host.name

        # A static import_role: (Task#is_static_import), like a block:,
        # produces no result of its own when skipped either - real
        # Ansible's static splice means there's nothing here to show
        # "skipping" for (see is_static_import's own comment). The
        # included role's own tasks simply never got spliced in, with no
        # trace of the import_role: statement itself in the recap.
        if nested_task.include_role? && nested_task.is_static_import?
          next
        end

        Krikri::OutputBanner.banner("TASK [#{task_role_prefix(nested_task)}#{render_task_name_for_display(nested_task, host)}]")
        puts "skipping: [#{connection_host}]".colorize(:cyan)
        # A skipped meta: task (e.g. a named meta: flush_handlers inside
        # a when:-false block) prints its "skipping:" line but is NOT
        # counted in the PLAY RECAP - ansible-core ignores meta
        # tasks in stats entirely (0x0i.systemd: krikri skipped=9 vs
        # ansible skipped=8, the extra one being exactly this shape).
        unless nested_task.module_name == "_meta"
          @results[host.name]["skipped"] += 1
          register_skip_result(nested_task, host)
        end
      end
    end

    # Runs a block: task - the nested block_tasks, then rescue_tasks if the
    # block failed (recovering it if rescue succeeds), then always_tasks
    # unconditionally, re-applying the halt afterward if the block ultimately
    # failed (unrescued, or rescue itself failed, or always: introduced a new
    # failure) unless the block itself has ignore_errors:.
    # Loop-item safety by VALUE, not by name (see UnsafeValues' own
    # comment): when the task's own loop SOURCE is a DIRECT reference to an
    # execution-resolved (unsafe) root, the values the loop yields are
    # already rendered data by the time they reach the per-item pass -
    # that pass would be their SECOND render, and rendering data-derived
    # text is exactly the controller code-execution hole the taint closes
    # (ansible-core marks such items AnsibleUnsafe and never
    # re-templates them). Callers therefore skip the per-item pass for
    # such loops and instead mark the resulting item VALUES in the
    # UnsafeValues exact-text registry, so every later re-render
    # (`msg: "{{ item }}"`, a module arg, a when:) is refused on the value
    # itself. Taint lives on the data, never on the `item` name: a name
    # taint cannot distinguish the values a hostile result produced from
    # the author-written template text that PRODUCED an item, and
    # suppressing the first render of author text is what left
    # geerlingguy.php's `with_items: ["{{ php_conf_paths | flatten }}",
    # "{{ php_extension_conf_paths | flatten }}"]` items verbatim
    # unrendered - no directories created at all.
    #
    # "Direct reference" is deliberately narrow AND whole-source only: the
    # source must be template-expression ONLY (a single `{{ ... }}` span
    # with no author literal text around it - `{{ r.stdout_lines }}`,
    # `{{ hostvars[...].r.y }}`, `{{ r.x | map('upper') | list }}`),
    # collected from the whole-source loop templates only. The literal
    # elements of a loop LIST are author template text whose render is
    # the items' first and only render - they are never taint sources,
    # whatever they reference (see loop_source_expressions). Hostile
    # content that flows INTO such a rendered item stays verbatim anyway
    # through the value-level UnsafeValues registry and mark_derived.
    private def loop_items_derive_from_unsafe_data?(task : Task, host_name : String) : Bool
      # A generic `with_<lookup>:` loop's items ARE lookup results (a
      # command's stdout for with_lines, a URL body for with_url) - real
      # Ansible marks every lookup result unsafe, so they are data, never
      # template text: rendering them ran `{{ lookup('pipe', ...) }}` that
      # a with_lines command merely printed.
      return true if task.loop_lookup_plugin
      referenced = Set(String).new
      loop_source_expressions(task).each do |source|
        next unless inner = direct_reference_expression?(source)
        inner.scan(/[A-Za-z_][A-Za-z0-9_]*/).each { |match| referenced.add(match[0]) }
      end
      return false if referenced.empty?
      referenced.any? { |name| VarSubstitutor.resolved_var_name?(host_name, name) }
    end

    # The task's whole-source loop template strings - everything EXCEPT
    # the literal elements of a loop list. A loop list's elements are
    # author template text (`"{{ paths | flatten }}"`,
    # `"{{ r.stdout }}"`, `"{{ ansible_os_family }}.yml"`) whose render
    # is the item's first and only render; only a WHOLE source that is
    # itself one bare direct reference (`loop: "{{ r.stdout_lines }}"`)
    # yields items that are already-rendered unsafe data.
    private def loop_source_expressions(task : Task) : Array(String)
      sources = [] of String
      if loop_template = task.loop_template
        sources << loop_template
      end
      {% for field in %w[loop_fileglob loop_file loop_first_found loop_first_found_paths
                        loop_flattened loop_nested_sources loop_together_sources loop_filetree] %}
        task.{{ field.id }}.try(&.each { |source| sources << source })
      {% end %}
      if subelements_list = task.loop_subelements_list
        sources << subelements_list
      end
      sources
    end

    # Publishes the final loop-item values of an unsafe-derived loop into
    # the value-level registry: any brace-bearing string in them is
    # verbatim data from here on, refused a re-render on every evaluation
    # path - the value-level replacement for the retired `item`-name
    # taint (see loop_items_derive_from_unsafe_data? and UnsafeValues).
    private def mark_unsafe_loop_items(items : Array(JSON::Any)) : Nil
      items.each { |item| UnsafeValues.mark_value(item) }
    end

    # *unsafe*: REMOVED - taint never suppresses a render. Loop items
    # taken from a whole-source direct reference to execution-resolved
    # data (see loop_items_derive_from_unsafe_data?) are skipped at the
    # call site (that pass would be their second render) and the resulting
    # values are marked in UnsafeValues instead; every item this method IS
    # called on is author-template text receiving its first render, with
    # hostile content inside it held verbatim by the UnsafeValues gates.
    private def deep_render_item(item : JSON::Any, vars_context : Hash(String, JSON::Any), host_name : String, depth : Int32 = 0, strict : Bool = true) : JSON::Any
      return item if depth > 10
      case raw = item.raw
      when Hash
        rendered = raw.each_with_object({} of String => JSON::Any) do |(key, value), acc|
          acc[key] = deep_render_item(value, vars_context, host_name, strict: strict)
        end
        JSON::Any.new(rendered)
      when Array
        JSON::Any.new(raw.map { |value| deep_render_item(value, vars_context, host_name, strict: strict) })
      when String
        return item if UnsafeValues.unsafe_text?(raw)
        return item unless raw.includes?("{{")

        # A raw value that's *exactly* one bare `{{ variable }}` span (no
        # surrounding text, no filter chain) resolves to the variable's
        # own native JSON type - matching Ansible's own templating,
        # which preserves the referenced value's type when the whole
        # input is a single expression, only falling back to string
        # concatenation for partial/mixed text. The general `substitute`
        # path below always stringifies (it has to - the general case
        # can mix literal text with an expression), which previously
        # silently turned every such role default into a string:
        # geerlingguy.php's own `pool_pm_max_requests: "{{
        # php_fpm_pm_max_requests }}"` (php_fpm_pm_max_requests: 0, a
        # real int meant to disable the request-count limit) rendered as
        # the STRING "0" - not falsy to Crinja's `default(500, true)`
        # filter the way the real int 0 is, so pm.max_requests stayed 0
        # instead of the role's own intended fallback of 500.
        stripped = raw.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}") && stripped.scan("{{").size == 1
          native = VariableSubstitutor::VariableLookup.new(vars_context).resolve(stripped[2..-3].strip)
          # Audit pass (2026-08-11, following the ansible-vault/
          # prometheus/grafana rounds finding 5 independent copies of
          # this exact bug): a variable whose own raw value is itself
          # still unrendered Jinja (a role default computed from
          # another default) must NOT be returned directly here - that
          # would hand back the literal, unparsed "{{ ... }}" text as
          # the loop item's "native" value.
          if native
            if (raw2 = native.raw).is_a?(String) && raw2.includes?("{{")
              # RECURSE (round165: buluma.confluence) rather than
              # falling through to the generic #substitute path below,
              # which always stringifies - correct for exactly ONE
              # level of indirection (`role_var: "{{ inner_var }}"`,
              # the common case), but a SECOND level (`role_var: "{{
              # _lookup[some_key] }}"`, itself resolving to another
              # unrendered "{{ }}" string, geerlingguy/buluma's own
              # release -> version -> download-dict indirection chain)
              # needs another #deep_render_item pass to preserve the
              # final dict's native Hash type instead of collapsing it
              # to a JSON-text STRING. Found live benchmarking buluma.
              # confluence: `loop: ["{{ confluence_download }}", "{{
              # postgresql_jdbc_download }}"]` (a real 2+-element loop -
              # a SINGLE-element array of one bare `{{ }}` expression
              # takes an entirely different, already-correct path via
              # #find_loop_template's own single-element special case,
              # which is why this only ever surfaced with 2+ items) -
              # `item` ended up bound to the STRINGIFIED dict text
              # instead of a real Hash, so `item.checksum` (a genuine
              # nested-hash dotted lookup) correctly reported
              # "undefined" against a value that was never actually a
              # Hash to begin with.
              return deep_render_item(JSON::Any.new(raw2), vars_context, host_name, depth + 1, strict: strict)
            end
            return native
          end

          # `native` is nil here for anything past a bare/dotted
          # reference - notably a filter chain (`{{ some_list | flatten
          # }}`), which #resolve doesn't attempt at all. Falling straight
          # to the generic #substitute path below would stringify a
          # list/dict-valued filter result the same way it stringifies
          # everything else, losing its native type exactly like the
          # bare-reference case above already guards against. Evaluate
          # it through the filter-chain evaluator instead and re-parse
          # the result as JSON when it looks like a list/dict - mirrors
          # resolve_loop_template's own filter-chain fallback
          # (expression_evaluator_for + parse_list_result). Found via
          # geerlingguy.php's own `with_items: ["{{ php_conf_paths |
          # flatten }}", "{{ php_extension_conf_paths | flatten }}"]`
          # (RHEL-family round 60100): each item stringified to its
          # filtered list's JSON text instead of staying a real array,
          # so with_items's own one-level flatten (which only unwraps an
          # actual Array) never fired - `path: "{{ item }}"` on the
          # `file:` module then received something as a whole, so
          # crystal reported `changed` on already-correct directories
          # where Ansible's actually-flattened, actually-scalar
          # `item` reported `ok`.
          begin
            evaluated = KrikriJinja.evaluate_expression(
              stripped[2..-3].strip, vars_context, strict: strict,
              host_context: JinjaHostContext.new(vars_context)
            )
            return evaluated if evaluated && (evaluated.as_a? || evaluated.as_h?)
          rescue
            # Not a list/dict, or not even valid JSON (an ordinary
            # rendered string) - fall through to the generic path below,
            # unchanged.
          end
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        # strict: true - Ansible templates the loop-source list itself
        # with module-arg (strict-undefined) semantics BEFORE any iteration
        # runs (igor_nikiforov.etcd: `loop: ["{{ etcd_conf_dir }}/certs",
        # "{{ etcd_config['data-dir'] }}"]` on a dict missing that key
        # fails the task with "object of type 'dict' has no attribute
        # 'data-dir'" - live-verified - where this engine used to render
        # the literal string "undefined" and run the whole play to
        # completion, rc=0, mkdir-ing directories named "undefined").
        # Callers that can't safely propagate the failure pass strict:
        # false (see each site's own comment).
        JSON::Any.new(substitutor.substitute(raw, strict: strict))
      else
        item
      end
    end

    # Substitute variables in task parameters
    private def inline_copy_source_content(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String) | JSON::Any
      return params unless task.module_name == "ansible.builtin.copy"
      # A truthy remote_src (in ANY boolean(strict=False) spelling or its
      # marked non-string literal form) hands the whole task to the copy
      # MODULE on the target (copy.py:466) - no controller-side src
      # resolution happens at all, not even a relative one: the module's
      # own missing-src failure ("Source <src> not found") is the whole
      # story. Previously only the four plain spellings matched here, so
      # a YAML-bool `remote_src: true` (wired as a marked non-string
      # literal) fell through to the controller lookup and reported
      # "Could not find or access" with the internal non-string marker
      # leaked into the searched paths, where Ansible fails on the target.
      return params if remote_src_param?(params)

      src = params["src"]?
      # A falsy non-string literal src (false/0/0.0 - the parser marks
      # those) is ignored by Ansible's copy action plugin (`not source`),
      # exactly like an absent or empty one - and so is a None one (a
      # YAML `src:` with no value, wired as NONE_SENTINEL, same as a
      # whole-span null template).
      src = "" if src == Krikri::NONE_SENTINEL
      return params unless src && Krikri.python_param_truthy?(src)

      # Ansible's copy action plugin resolves a relative src against
      # the role's files/ dir, the playbook dir, and the task's dir
      # before anything else. krikri only ever looked at absolute paths
      # here, so a playbook-relative `src: files/m4-tree/` reached the
      # plugin binary unresolved and failed on the target with "Source
      # file not found" (found live via modules_data.yml). Resolve it
      # against the same roots first_found uses, then rewrite src to the
      # absolute controller path so every downstream check (existence,
      # size, vault decrypt, directory staging) sees the real file.
      #
      # The resolution (and the missing-src failure) applies on a LOCAL
      # connection too: the target IS the controller there, so Ansible's
      # action plugin still fails a src: that exists nowhere with its
      # controller-side wording - previously the local early-return let
      # the plugin binary run and report its own "Source file not found"
      # msg instead (live-verified against 2.19.11 under -c local).
      local_connection = PluginManager.local_connection?(host, vars_context)
      if !src.starts_with?('/')
        roots = [] of String
        task.role_files_dir.try { |dir| roots << dir }
        task.include_file_dir.try { |dir| roots << dir }
        roots << @playbook_dir
        roots << Dir.current
        resolved = first_existing(roots, src)
        if resolved
          src = File.expand_path(resolved)
          params = params.dup
          params["src"] = src
        else
          # Ansible's _find_needle miss on the controller - a relative src,
          # so the failure carries the full Searched-in list (both
          # connection flavors live-verified against 2.19.11).
          candidates = NeedleLookup.candidates(
            NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)),
            File.expand_path(@playbook_dir), "files", src)
          return controller_missing_copy_local_result(src, candidates) if local_connection
          return controller_missing_copy_result(src, candidates)
        end
      elsif local_connection
        # Absolute src on a local connection: the controller-side
        # existence check IS the whole story (same filesystem), so a
        # miss fails here with Ansible's wording instead of reaching the
        # plugin binary. An absolute src builds no searched-paths list
        # in real (its absolute lookup branch never populates one).
        is_directory = Dir.exists?(src) rescue false
        return params if is_directory
        return controller_missing_copy_local_result(src, [] of String) unless File.exists?(src)
        return params
      end

      # Ansible's copy action plugin fails the task on the
      # CONTROLLER before anything runs when src: names a file that
      # doesn't exist there ("Could not find or access '<src>' on the
      # Ansible Controller.") - including under --check, which reports
      # failed=1 on every host. Previously a missing src silently fell
      # through (the size check below returned params unchanged), the
      # plugin ran in check mode with nothing to compare, and the task
      # reported a green ok - a check-mode run that should have
      # hard-failed came out fully green.
      is_directory = Dir.exists?(src) rescue false
      return stage_directory_copy_source(params, src, host, vars_context) if is_directory

      size = File.size(src) rescue nil
      return controller_missing_copy_result(src, [] of String) unless size

      # Ansible's `copy:` auto-decrypts a vault-armored src on the
      # CONTROLLER before transfer (decrypt: true is the default;
      # decrypt: false keeps the ciphertext) - without this the
      # ciphertext was uploaded verbatim, i.e. krikri behaved like
      # decrypt: false on every run. A Vault::Error (missing/wrong
      # password) propagates, matching every other maybe_decrypt call
      # site: it aborts via krikri-playbook.cr's top-level rescue with
      # the clear decrypt-failure message.
      if copy_decrypt_enabled?(params) && vault_encrypted_file?(src)
        decrypted = Vault.maybe_decrypt(File.read(src))
        # An oversized decrypted file - or a decrypted plaintext that is
        # itself binary (e.g. a vaulted keyring, which JSON-transported
        # content: would mangle the same way a plaintext binary src is
        # mangled) - takes the byte-safe SCP staging path: the decrypted
        # bytes are written to a scratch file NAMED AFTER the original
        # src so the basename-derived behavior downstream (dest-is-
        # directory appending, the checksum-first match) still sees the
        # real name.
        if size > INLINE_COPY_MAX_BYTES || !decrypted.valid_encoding?
          tmpdir = File.join(Dir.tempdir, "krikri-copy-vault-#{Random::Secure.hex(8)}")
          Dir.mkdir_p(tmpdir, 0o700)
          staged = File.join(tmpdir, File.basename(src))
          # Decrypted plaintext: restrict perms before the bytes land, and
          # guarantee cleanup even if the transfer raises mid-flight - a
          # leaked copy of the secret must not outlive this call.
          File.chmod(tmpdir, 0o700)
          File.open(staged, "w") do |file|
            file.chmod(0o600)
            file.write(decrypted.to_slice)
          end
          begin
            result = stage_large_copy_source(params, staged, host, vars_context)
          ensure
            FileUtils.rm_r(tmpdir)
          end
          return result
        end

        resolved = params.dup
        resolved.delete("src")
        resolved["content"] = decrypted
        resolved["__original_src_basename"] = File.basename(src)
        return resolved
      end

      if size > INLINE_COPY_MAX_BYTES
        return stage_large_copy_source(params, src, host, vars_context)
      end

      begin
        content = File.read(src)
      rescue
        return params
      end

      # BINARY (not valid UTF-8) source: never inline it as `content:`.
      # The params ride to the remote plugin as JSON, and JSON is a
      # UTF-8 format - serializing a String holding invalid byte
      # sequences mangles them (observed live: a 4702-byte OpenPGP
      # keyring round-tripped to 8394 bytes of U+FFFD-substituted
      # garbage), so the file installed on the target is corrupt even
      # though the task reports changed and every checksum comparison
      # against the equally-corrupt destination still "passes". Real
      # victim: systemli.apt_repositories' keyring copy
      # (`copy: {src: prosody-debian-packages.gpg, dest:
      # /usr/share/keyrings/...}`) - apt then failed "Update cache" with
      # NO_PUBKEY F7A37EB33D0B25D7, because the keyring it read was
      # garbage. Take the byte-safe SCP staging path instead, exactly
      # like an oversized file would.
      return stage_large_copy_source(params, src, host, vars_context) unless content.valid_encoding?

      resolved = params.dup
      resolved.delete("src")
      resolved["content"] = content
      # copy.cr's own handle_content_copy needs this to append the
      # right basename when dest: is an existing directory - see that
      # call site's own comment for the full "Is a directory" story.
      resolved["__original_src_basename"] = File.basename(src)
      resolved
    end

    # Ansible's own failure text for a controller-side src: miss
    # (copy action plugin) - byte-identical to the unarchive variant
    # below so divergence triage compares cleanly against a real
    # ansible-playbook run of the same role. A relative src carries the
    # full Searched-in list (Ansible's AnsibleFileNotFound paths); an
    # absolute one carries none (Ansible's absolute lookup branch never
    # populates one).
    private def controller_missing_copy_result(src : String, candidates : Array(String)) : JSON::Any
      result = JSON.parse({
        "changed" => false,
        "failed"  => true,
        "msg"     => "Task failed: #{NeedleLookup.not_found_message(src, candidates)}",
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_MSG_FIRST)
      result
    end

    # copy:'s controller-side src: miss on a LOCAL connection: real
    # 2.19.11's fatal msg carries the "Unexpected AnsibleActionFail
    # error: " prefix itself, WITHOUT the "Task failed: " prefix the
    # remote-host variant above carries (both live-verified).
    private def controller_missing_copy_local_result(src : String, candidates : Array(String)) : JSON::Any
      result = JSON.parse({
        "changed" => false,
        "failed"  => true,
        "msg"     => "Unexpected AnsibleActionFail error: #{NeedleLookup.not_found_message(src, candidates)}",
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_MSG_FIRST)
      result
    end

    # copy:'s decrypt: param (Ansible default true): only an
    # explicit falsy ("false"/"no"/"0"/"off") opts OUT of controller-side
    # vault decryption of src - the inverse of remote_src's truthy check
    # above, because the default points the other way.
    private def copy_decrypt_enabled?(params : Hash(String, String)) : Bool
      !["false", "no", "0", "off"].includes?(params["decrypt"]?.try(&.downcase))
    end

    # True if *path*'s first line carries the vault armor header - a
    # one-line peek, not a full read, so a large non-vault src never pays
    # for a whole-file read just to make the routing decision.
    private def vault_encrypted_file?(path : String) : Bool
      File.open(path) { |file| file.read_line.starts_with?(Vault::HEADER_PREFIX) }
    rescue
      false
    end

    # Large-file counterpart to the inline `content` path above: SCPs
    # *src* straight to a remote scratch path (no content embedded in
    # the JSON config at all - just a path string, same size regardless
    # of how big the underlying file is) and points the module at that
    # instead. `copy.cr`'s own handle_file_copy already reads `src` from
    # whatever filesystem the plugin process is actually running on, so
    # once the file is really present on the target, no other change is
    # needed there beyond deleting the scratch copy afterward (via the
    # `__cleanup_after_copy` marker param).
    private def stage_large_copy_source(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      connection_host = PluginManager.get_connection_host(host, vars_context)

      if match = precomputed_copy_match(params, src, host, vars_context)
        return match
      end

      remote_tmp = "/tmp/.krikri-playbook-copy-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["__cleanup_after_copy"] = "true"
      # copy.cr's own "dest is an existing directory" handling appends
      # File.basename(src) to dest - without this, that would append the
      # random scratch filename (".krikri-playbook-copy-<hex>") instead
      # of the real source's name, installing e.g. Vault's binary as
      # "/usr/local/bin/.krikri-playbook-copy-<hex>" rather than
      # "/usr/local/bin/vault". Real bug found immediately after adding
      # the staging path above, benchmarking the same ansible-vault role.
      resolved["__original_src_basename"] = File.basename(src)
      resolved
    end

    # Checksum-first skip for a large controller->remote `copy:` upload,
    # matching Ansible's own `copy:` behavior (it computes the
    # source checksum locally and stats the destination remotely before
    # ever transferring content, skipping the transfer entirely on a
    # match). Previously #stage_large_copy_source unconditionally SCP'd
    # *src* to a remote scratch path on every single run regardless of
    # whether the destination already held identical content - fine for
    # a one-time install, wasteful for a large binary (tens of MB) on
    # every warm rerun of a role like prometheus.prometheus's own
    # binary-propagation task (round 25/26/27's alertmanager/
    # blackbox_exporter benchmark rounds all hit this).
    #
    # One remote round trip (not two): resolves the real destination
    # path (appending the source's basename if `dest` is already an
    # existing directory - copy.cr's own `handle_file_copy` does the
    # same resolution once it actually runs, so this must match it
    # exactly or a mismatch would silently skip a needed copy) and
    # sha1sums it in the same script, only if it exists (SHA1, not the
    # MD5 this used to compare - the compared value doubles as the
    # result's `checksum:` field, which Ansible reports as SHA1).
    #
    # Returns the resolved params for the caller to use as-is (with
    # `src` left pointing at the untouched local file - the plugin body
    # never reads it in the match case) when the checksums match, or
    # `nil` when they don't (or the match couldn't be determined),
    # telling the caller to fall through to its normal unconditional
    # upload path unchanged.
    private def precomputed_copy_match(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)?
      # force: false's own "dest exists at all -> unchanged, no
      # checksum involved" short-circuit lives entirely in copy.cr and
      # doesn't need src staged either way - simplest to just leave that
      # case to the normal (always-safe) unconditional-upload path
      # rather than teach this checksum-first optimization about it too.
      return nil if ["false", "no", "0", "off"].includes?(params["force"]?.try(&.downcase))

      dest = params["dest"]?
      return nil unless dest

      local_sha1 = begin
        Digest::SHA1.new.file(src).hexfinal
      rescue
        return nil
      end

      basename = File.basename(src)
      script = <<-SCRIPT
        p=#{shell_single_quote(dest)}
        [ -d "$p" ] && p="$p/#{basename.gsub("'", "'\\''")}"
        if [ -f "$p" ]; then sha1sum "$p" | cut -d' ' -f1; else echo NOFILE; fi
        SCRIPT

      connection_host = PluginManager.get_connection_host(host, vars_context)
      result = SSHManager.exec_script(
        connection_host,
        host.user || "root",
        script,
        host.port,
        identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
      )
      return nil unless result[:exit_code] == 0 && result[:stdout].strip == local_sha1

      resolved = params.dup
      resolved["__precomputed_match"] = "true"
      resolved["__precomputed_checksum"] = local_sha1
      resolved["__original_src_basename"] = basename
      resolved
    rescue
      nil
    end

    # Single-quotes *str* for shell embedding, escaping any embedded
    # single quote - same convention as BasePlugin/BatchScript/
    # PluginManager's own copies of this helper (each kept separate
    # rather than shared across unrelated classes).
    private def shell_single_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    # Directory counterpart to #stage_large_copy_source: SCPs the whole
    # source directory tree to a remote scratch path (`scp -r`) instead
    # of leaving `src` pointing at a path that only exists on the
    # controller - `copy.cr`'s own directory-copy logic already reads
    # `src` from wherever the plugin process is actually running, so
    # once the directory is really present on the target, no other
    # change is needed there beyond deleting the scratch copy afterward.
    #
    # Note what this deliberately does NOT handle: per-file vault
    # decryption inside the tree. Ansible's directory copy runs each
    # file through the same decrypt: machinery as a single-file src:, but
    # this path `scp -r`s the directory without ever reading individual
    # files in Crystal, so a vault-encrypted file inside a copied
    # directory is transferred as ciphertext. Left unhandled - no real
    # role round has hit a vaulted file inside a directory copy.
    private def stage_directory_copy_source(params : Hash(String, String), src : String, host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.krikri-playbook-copy-dir-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src.rstrip('/'),
          remote_tmp,
          host.port,
          mode: nil,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?),
          recursive: true
        )
      rescue
        return params
      end

      resolved = params.dup
      # `scp -r src remote_tmp` (remote_tmp not previously existing)
      # makes remote_tmp itself an exact copy of src's contents - the
      # trailing "/" on the ORIGINAL src: value still has to be
      # preserved here, since copy.cr's own directory-copy dispatch uses
      # it (Ansible's own convention) to decide whether src's
      # contents land directly in dest or as a dest/<basename> subdir.
      resolved["src"] = src.ends_with?('/') ? "#{remote_tmp}/" : remote_tmp
      resolved["__cleanup_after_copy_dir"] = "true"
      resolved
    end

    # unarchive:'s own Ansible default (remote_src: false, not
    # documented as such in this codebase before) means `src:` names a
    # file on the CONTROLLER, not the target - same category of gap
    # inline_copy_source_content/stage_large_copy_source already solve
    # for copy:, mirrored here via the same SCP-staging approach (an
    # archive is arbitrary binary data, so the "embed as content:"
    # shortcut copy: uses for small files doesn't apply; always stages
    # via SCP regardless of size, matching stage_large_copy_source's own
    # unconditional approach for a directory/big-file copy).
    #
    # unarchive.cr itself always runs its tar/unzip commands against
    # whatever filesystem it's actually executing on (the remote target,
    # once uploaded and run there like every other plugin) - previously
    # had no notion at all that `src:` might still be sitting on the
    # controller, so `remote_file_exists?(src)` always failed once a
    # play used a genuinely remote host and a controller-side src: path.
    # Found via prometheus.prometheus.node_exporter's own "Unpack binary
    # archive" task: the binary was downloaded to a `delegate_to:
    # localhost` cache dir (a real, common pattern for a role that
    # downloads once and extracts per-target), and the following
    # unarchive: task (no delegate_to, running on the real target) never
    # had that file transferred to it at all - "Source ... failed to
    # transfer" regardless of the file genuinely existing, just on the
    # wrong host.
    # Ansible's unarchive action plugin checks `src:` against the
    # CONTROLLER only, unconditionally, when remote_src is false (the
    # default) - there is no "maybe it's already on the remote" fallback,
    # and a controller-side miss is a hard task failure:
    #   "Task failed: Could not find or access '<src>' on the Ansible
    #   Controller.\nIf you are using a module and expect the file to
    #   exist on the remote, see the remote_src option"
    # (verified live against ansible-core 2.19). Previously a controller
    # miss silently returned params unchanged, so the plugin ran anyway
    # and its remote_file_exists? check found the file ON THE TARGET -
    # exactly the shape get_url downloads into - and succeeded where real
    # Ansible fails. Found via andrewrothstein.func_e (round 810153):
    # get_url pulls the tarball to the remote /tmp, then unarchive: with
    # no remote_src: (and arguably a buggy role) must fail per real
    # Ansible, not paper over it.
    #
    # Returns either the (possibly rewritten) params hash on success, or
    # a JSON::Any failed-task result the caller must turn into a task
    # failure via apply_changed_failed_when (same shape the param-
    # substitution rescue blocks build).
    private def stage_unarchive_remote_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String) | JSON::Any
      return params unless task.module_name == "ansible.builtin.unarchive"
      return params if ansible_boolean_param?(params["remote_src"]?)
      # copy: is unarchive's OLDER param spelling, mutually exclusive
      # with remote_src: per Ansible's own argument_spec, and
      # INVERTED - copy: false means the same thing as remote_src: true
      # ("the file is already on the target, don't copy it from the
      # controller"). CVi.thanos (round 812047, confirming this staging
      # fix's own 0.9.1048 controller-src work) uses `copy: no` on a
      # task whose src: was downloaded straight to the remote by an
      # earlier task - without this check that reads as remote_src:
      # false (the default), so staging looked for src: on the
      # CONTROLLER, found nothing, and failed the task where real
      # Ansible (which treats copy: no identically to remote_src: true)
      # succeeds.
      return params if params.has_key?("copy") && !ansible_boolean_param?(params["copy"]?)

      src = params["src"]?
      # A None src (`src:` with no value - NONE_SENTINEL, same as a
      # whole-span null template) fails the module's own required-argument
      # check downstream, exactly like the empty string always did.
      src = "" if src == Krikri::NONE_SENTINEL
      return params if src.nil? || src.empty?
      # URL sources are downloaded by the plugin itself - never stage.
      return params if src.starts_with?("http://") || src.starts_with?("https://")

      original_src = src

      # A bare relative src: names a controller-side file in the role's
      # own files/ dir (Ansible's unarchive action plugin searches
      # there via _find_needle, same convention copy:/template:/script:
      # use). Previously only an ABSOLUTE controller path was staged, so
      # `unarchive: src: "{{ package_name }}"` with
      # package_name="minio.tar.gz" handed the plugin a bare name that
      # failed remote_file_exists? - "Source 'minio.tar.gz' failed to
      # transfer" (wezhai.minio on Debian trixie, where tar exists and
      # the gap actually surfaces).
      unless src.starts_with?('/') && File.exists?(src)
        resolved_local = resolve_script_path(src, task)
        # resolve_script_path covers both the role's files/ dir and a
        # path relative to the controller's own cwd - if neither has it,
        # Ansible's controller-side lookup has run out of places to
        # look and the task fails here, before the plugin ever runs.
        return controller_missing_unarchive_result(original_src, unarchive_candidates(task, original_src)) unless resolved_local
        src = resolved_local
      end
      return controller_missing_unarchive_result(original_src, unarchive_candidates(task, original_src)) unless File.exists?(src)

      # A local connection runs the plugin on the controller itself -
      # hand it the resolved ABSOLUTE path, no staging (the transfer-
      # related remote_src/__cleanup flags below are meaningless there).
      if PluginManager.local_connection?(host, vars_context)
        resolved = params.dup
        resolved["src"] = src
        return resolved
      end

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.krikri-playbook-unarchive-src-#{Random::Secure.hex(8)}-#{File.basename(src)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["remote_src"] = "true"
      resolved["__cleanup_after_unarchive"] = "true"
      resolved
    end

    # Ansible's own failure text for a controller-side src: miss
    # (unarchive action plugin, remote_src: false) - byte-identical so
    # divergence triage compares cleanly against a ansible-playbook
    # run of the same role. A relative src carries the full Searched-in
    # list (live-verified against 2.19.11); an absolute one none.
    private def controller_missing_unarchive_result(src : String, candidates : Array(String)) : JSON::Any
      result = JSON.parse({
        "changed" => false,
        "failed"  => true,
        "msg"     => "Task failed: #{NeedleLookup.not_found_message(src, candidates)}",
      }.to_json)
      Krikri.mark_failed_key_order(result, FAILED_KEY_ORDER_EXCEPTION_FIRST)
      result
    end

    private def unarchive_candidates(task : Task, src : String) : Array(String)
      return [] of String if src.starts_with?('/') || src.starts_with?("~")
      NeedleLookup.candidates(
        NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)),
        File.expand_path(@playbook_dir), "files", src)
    end

    # script:'s free-form `cmd` (or bare-string `_raw_params`, resolved to
    # `cmd` by RAW_COMMAND_MODULES parsing either way) is "<local path>
    # [args...]" - the path always names a file on the CONTROLLER, same
    # category of gap as unarchive:'s src: (see
    # #stage_unarchive_remote_src). Resolves the path against the
    # currently-executing role's own files/ dir first (Ansible's own
    # script: action plugin searches there, same convention copy:/
    # template: use), then falls back to whatever's resolvable relative to
    # the controller's own cwd. A local connection needs the path resolved
    # (a role-relative name isn't meaningful relative to the plugin
    # process's own cwd otherwise) but never staged - the plugin process
    # already runs directly on the controller's filesystem in that case.
    private def stage_script_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String) | JSON::Any
      return params unless task.module_name == "ansible.builtin.script"

      cmd = params["cmd"]? || params["_raw_params"]?
      return params unless cmd
      # Ansible's script action plugin runs the task args through
      # validate_argument_spec (type str) before the _find_needle lookup,
      # so a non-string YAML literal (the parser marks those; see
      # NON_STRING_PARAM_PREFIX) renders through Python str() there - bools
      # become "True"/"False" - and the file is searched for, and reported
      # missing ("Could not find or access '75'"), under that text. Without
      # this the internal marker prefix leaked into the message and every
      # Searched-in path (live-verified vs 2.19.11).
      if native = Krikri.non_string_scalar(cmd)
        cmd = Krikri.python_str_scalar(native)
      end

      parts = cmd.strip.split(/\s+/, 2)
      local_path = parts[0]?
      return params if local_path.nil? || local_path.empty?
      rest = parts[1]?

      resolved_local = resolve_script_path(local_path, task)
      unless resolved_local
        # Ansible's script action plugin fails the task ON THE CONTROLLER
        # when _find_needle can't find the file - an AnsibleActionFail
        # carrying the loader's not-found text verbatim (no
        # "Task failed: " prefix; the Searched-in list for a relative
        # src, none for an absolute one - both live-verified against
        # 2.19.11). Previously the task fell through to the plugin
        # binary and failed with an unrelated transfer message.
        candidates = if local_path.starts_with?('/') || local_path.starts_with?("~")
                       [] of String
                     else
                       NeedleLookup.candidates(
                         NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)),
                         File.expand_path(@playbook_dir), "files", local_path)
                     end
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => NeedleLookup.not_found_message(local_path, candidates),
        }.to_json)
      end

      if PluginManager.local_connection?(host, vars_context)
        resolved = params.dup
        resolved["cmd"] = rest ? "#{resolved_local} #{rest}" : resolved_local
        return resolved
      end

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.krikri-playbook-script-#{Random::Secure.hex(8)}-#{File.basename(resolved_local)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          resolved_local,
          remote_tmp,
          host.port,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["cmd"] = rest ? "#{remote_tmp} #{rest}" : remote_tmp
      resolved["__cleanup_after_script"] = "true"
      resolved
    end

    # Resolves script:'s leading path token against (in order) the
    # currently-executing role's own files/ dir, then the controller's own
    # cwd (an absolute path, or a relative one for a playbook invoked from
    # its own directory - the common case). nil if it can't be found
    # anywhere, in which case the caller leaves params untouched and the
    # normal "file not found on target" failure surfaces from script.cr
    # itself once uploaded/executed.
    # assemble with a remote_src the action plugin treats as falsy
    # (boolean(strict=False) - see Krikri.lenient_boolean_true?): Ansible's
    # action assembles the fragments on the CONTROLLER and delegates the
    # placement to the copy module, so the action's controller-side touch
    # points run before anything else - live-verified vs 2.19.11:
    # - _find_needle('files', src): a src that resolves nowhere fails the
    #   task right there with the loader's not-found text ("Task failed:
    #   Could not find or access ..." - Searched-in list for a relative
    #   src, none for an absolute one), BEFORE the isdir() check and
    #   before any module-level argument validation;
    # - the fragment loop's codecs.escape_decode(delimiter): a TRUTHY
    #   non-string literal delimiter raises TypeError
    #   "a bytes-like object is required, not '<type>'" - but only once a
    #   SECOND fragment is reached (the delimiter write is gated on the
    #   previous fragment), so a single-fragment src assembles fine;
    # - the isdir() failure ("Source (...) is not a directory") sits
    #   between the two, so the plugin's own action-level emission still
    #   wins over the delimiter crash for a src that exists but is not a
    #   directory (guarded here by Dir.exists?).
    private def stage_assemble_dir(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String) | JSON::Any
      return params unless task.module_name == "ansible.builtin.assemble"
      return params if params["remote_src"]?.nil? || Krikri.lenient_boolean_true?(params["remote_src"]?)

      src = params["src"]?
      if src && !src.empty? && src != Krikri::NONE_SENTINEL && !File.exists?(src)
        candidates = assemble_candidates(task, src)
        bare = NeedleLookup.not_found_message(src, candidates)
        return JSON.parse({
          "changed"               => false,
          "failed"                => true,
          "msg"                   => "Task failed: #{bare}",
          "_ansible_error_detail" => bare,
          "_ansible_action_level" => true,
        }.to_json)
      end
      return params unless src && Dir.exists?(src)

      # re.compile(regexp) sits between the isdir() check and the fragment
      # loop: a non-string LITERAL regexp (any non-None value - the check
      # is `if regexp is not None`, so falsy literals crash too) fails
      # here, before the delimiter write could (live-verified vs 2.19.11).
      # An invalid regexp STRING raises Python's sre error text, which has
      # no Crystal equivalent - not emulated (krikri treats it as no
      # filter).
      if (raw = params["regexp"]?) && raw != Krikri::NONE_SENTINEL &&
         Krikri.non_string_scalar(raw)
        return literal_crash_result("first argument must be string or compiled pattern")
      end

      if crash = assemble_delimiter_literal_crash(params, src)
        return crash
      end

      return params if PluginManager.local_connection?(host, vars_context)

      connection_host = PluginManager.get_connection_host(host, vars_context)
      remote_tmp = "/tmp/.krikri-playbook-assemble-#{Random::Secure.hex(8)}"

      begin
        SSHManager.upload(
          connection_host,
          host.user || "root",
          src.rstrip('/'),
          remote_tmp,
          host.port,
          mode: nil,
          identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?),
          recursive: true
        )
      rescue
        return params
      end

      resolved = params.dup
      resolved["src"] = remote_tmp
      resolved["__cleanup_after_assemble"] = "true"
      resolved
    end

    # Ansible's assemble action resolves src through _find_needle('files',
    # src) - the same role files/ search stack copy/script/unarchive use.
    private def assemble_candidates(task : Task, src : String) : Array(String)
      return [] of String if src.starts_with?('/') || src.starts_with?("~")
      NeedleLookup.candidates(
        NeedleLookup.search_stack(task.role_path, task.role_parent_paths, needle_task_file_dir(task)),
        File.expand_path(@playbook_dir), "files", src)
    end

    # The delimiter crash Ansible's assemble action hits on a TRUTHY
    # non-string YAML literal delimiter (the parser marks those; see
    # NON_STRING_PARAM_PREFIX): codecs.escape_decode(delimiter) inside
    # _assemble_from_fragments raises TypeError "a bytes-like object is
    # required, not '<type>'" - but only when a second fragment follows
    # the first (the delimiter is written BETWEEN fragments), so the
    # fragment filters (isfile, ignore_hidden truthiness, regexp) decide
    # whether the crash fires at all. A falsy literal (0/0.0/false/None)
    # skips the `if delimiter:` branch entirely, and a plain string
    # decodes fine. Not emulated here: the regexp compile crash real
    # raises first for a non-string/invalid regexp (its sre error text
    # has no Crystal equivalent) - with both broken, real names the
    # regexp, krikri the delimiter.
    private def assemble_delimiter_literal_crash(params : Hash(String, String), src : String) : JSON::Any?
      return nil unless native = Krikri.non_string_scalar(params["delimiter"]?)
      return nil unless Krikri.python_param_truthy?(params["delimiter"]?)
      ignore_hidden = params["ignore_hidden"]?
      ignore_hidden = "" if ignore_hidden == Krikri::NONE_SENTINEL
      ignore_hidden_truthy = Krikri.python_param_truthy?(ignore_hidden)
      regexp = params["regexp"]?.try { |raw| Regex.new(raw) rescue nil }
      fragments = Dir.children(src).sort.count do |name|
        next false if ignore_hidden_truthy && name.starts_with?('.')
        full = File.join(src, name)
        next false unless File.file?(full)
        regexp.nil? || regexp.matches?(name)
      end
      return nil unless fragments >= 2
      literal_crash_result("a bytes-like object is required, not '#{Krikri.python_value_type_name(native)}'")
    end

    # Build plugin configuration
    private def build_plugin_config(
      task : Task,
      host : Host,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
      become_user : String? = task.become_user,
      substituted_env : Hash(String, String)? = nil,
    ) : String
      # Add check_mode and diff_mode to params
      final_params = params.dup
      final_params["_ansible_check_mode"] = resolve_task_check_mode(task, vars_context).to_s
      final_params["_ansible_diff"] = @diff_mode.to_s
      # The module name exactly as the playbook invoked it - real
      # Ansible's check-mode skip message echoes it ("remote module
      # (ansible.builtin.tempfile) does not support check mode", see
      # tempfile.cr), and the plugin has no other way to recover the
      # invoked spelling after FQCN-stripping dispatch.
      final_params["_module_name"] = task.module_name
      # debug.cr's own verbosity: gate reads this back out - previously
      # never set at all, so a role's `debug: ... verbosity: 2` always
      # compared against a hardcoded 0 regardless of real -v/-vv/-vvv
      # flags (see debug.cr's own comment on `_verbosity`).
      final_params["_verbosity"] = @verbosity.to_s

      # setup:'s discovered_interpreter_python stamp - Ansible emits
      # it on the host's FIRST module invocation that runs interpreter
      # discovery, never after (see first_gather_for_host?); the gate is
      # executor state, so it is threaded to the gatherer here and in the
      # implicit Gathering Facts path. A direct gather_facts: task is the
      # same thing (an action plugin delegating to setup), so it gets the
      # identical gate - on a gather_facts: false play its invocation IS
      # the host's first gather.
      if ["setup", "gather_facts"].includes?(task.module_name.split(".").last)
        final_params["_first_gather"] = first_gather_for_host?(host).to_s
      end

      # environment: - substituted STRICTLY (UndefinedVariableError on an
      # undefined reference) ahead of this call, inside the same protected
      # "finalization of task args" block as substitute_task_params - see
      # substitute_task_environment. Forwarded as a single JSON blob under
      # a reserved param key; BasePlugin#remote_exec/#local_exec read it
      # back out and prefix whatever command the plugin shells out with
      # the equivalent `export K=V; ...` - applies uniformly to every
      # plugin that shells out (command/shell/apt/systemctl/...) rather
      # than needing separate wiring per plugin.
      final_params["_environment"] = substituted_env.to_json if substituted_env

      # Only debug:/assert: actually read the vars context inside the
      # plugin process (BasePlugin itself only ever pulls 3 connection
      # keys out of it - see PluginManager::NEEDS_FULL_VARS). Everyone
      # else gets just those 3 keys instead of the full context, which
      # for a typical templating-heavy task is tens to hundreds of KB of
      # JSON (up to ~570 KB seen after a package_facts: task) that would
      # otherwise be base64'd over SSH and immediately discarded by the
      # plugin that receives it. `playbook_dir` is a fourth key, and not
      # a connection detail: it is the module's own working directory
      # under a local connection (Ansible's local connection plugin
      # runs every module with cwd = the playbook's directory, so any
      # relative path a module resolves - tempfile's `path:`, for one -
      # is relative to the playbook, not to the shell the playbook was
      # launched from), and tempfile.cr needs it to reproduce that.
      wire_vars = if PluginManager.needs_full_vars?(task.module_name)
                    vars_context
                  else
                    pruned = Hash(String, JSON::Any).new
                    {"ansible_connection", "ansible_host", "ansible_ssh_private_key_file", "playbook_dir"}.each do |key|
                      if v = vars_context[key]?
                        pruned[key] = v
                      end
                    end
                    pruned
                  end

      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port,
        },
        "params" => final_params,
        "vars"   => wire_vars,
        # Read by PluginManager, not by the plugin binary itself - become:
        # wraps the *whole* plugin process (local spawn or the remote SSH
        # command) in `sudo -n -u <user> --`, rather than being something
        # each plugin has to know about individually. Carried as plain
        # top-level config fields (not nested under "params") so this
        # round-trips through async:'s job file (written verbatim from this
        # same config) without __async_run needing any extra plumbing.
        "become"      => task.become?.to_s,
        "become_user" => become_user,
      }

      # The per-host unsafe-name registry, serialized only for the plugins
      # whose binary actually reads the vars context (debug:/assert: - the
      # same set that pays for full `vars` above): an `async:` task runs
      # its module in a DETACHED process (`__async_run`, or the uploaded
      # binary on a remote target) whose own VarSubstitutor/UnsafeValues
      # registries start empty, so without this snapshot that process's
      # re-render gates are blind and a hostile module result could be
      # re-templated there. VarSubstitutor.hydrate_unsafe_registry_from_
      # config rebuilds both registries from it before the plugin runs.
      if PluginManager.needs_full_vars?(task.module_name)
        config_hash = JSON.parse(config.to_json).as_h
        config_hash["unsafe_registry"] = JSON::Any.new({
          "host"  => JSON::Any.new(host.name),
          "hosts" => JSON::Any.new(VarSubstitutor.resolved_names_snapshot.transform_values do |names|
            JSON::Any.new(names.map { |name| JSON::Any.new(name) })
          end),
        })
        config_hash.to_json
      else
        config.to_json
      end
    end

    # Matches Ansible's `stdout_lines`/`stderr_lines` (built from
    # Python's `str.splitlines()`), not Crystal's plain `String#split("\n")`.
    # The rationale (empty input, trailing-newline cases - and the UFW role
    # that found them) lives with the shared implementation in
    # plugin_helpers/ansible_splitlines.cr, which the command/shell plugins
    # now also use for their own module-side *_lines keys.
    private def ansible_splitlines(text : String) : Array(String)
      PluginHelpers::AnsibleSplitlines.split(text)
    end

    # Ansible's copy action plugin rejects src+content together before the
    # src file is even looked at (live-verified: the mutual-exclusion
    # error wins over a MISSING src too, and an EMPTY src is simply
    # ignored - `src: ""` + content runs the content path, no conflict).
    # Runs before inline_copy_source_content so the task's own src wins
    # the conflict detection instead of being consumed by the inliner.
    private def copy_src_content_conflict(task : Task, params : Hash(String, String)) : JSON::Any?
      return nil unless task.module_name == "ansible.builtin.copy"
      src = params["src"]?
      # Ansible's check is Python truthiness (`source and content is not
      # None`): a falsy non-string literal src (false/0/0.0 - the parser
      # marks those) is simply ignored and the content path runs, and so
      # is a None one (a YAML `src:` with no value - the parser wires
      # literal nulls as NONE_SENTINEL, same as a whole-span null
      # template).
      return nil unless src && src != Krikri::NONE_SENTINEL && Krikri.python_param_truthy?(src)
      return nil unless params.has_key?("content")
      JSON.parse({"changed" => false, "failed" => true, "msg" => "src and content are mutually exclusive"}.to_json)
    end

    # Real copy.py's action-plugin crashes on non-string YAML literal
    # dest/src values (the parser marks those; see NON_STRING_PARAM_PREFIX):
    # Python evaluates `dest.endswith(...)`/`source.endswith(...)` on the
    # NATIVE int/float/bool and raises AttributeError, which the task
    # executor wraps as fatal msg "Task failed: '<type>' object has no
    # attribute '<attr>'" (live-verified vs 2.19.11: ints report
    # _AnsibleTaggedInt, floats _AnsibleTaggedFloat, bools plain 'bool').
    # Mirrors the three crash points that precede src resolution/content
    # inlining, in Ansible's order:
    # - content + truthy non-string dest: `dest.endswith("/")` in the
    #   required/conflict elif chain (copy.py:433);
    # - no content, not remote_src: `source.endswith(os.path.sep)` before
    #   find_needle (copy.py:469) - the src crash wins over a missing src;
    # - a real directory src: `_shell.path_has_trailing_slash(dest)`
    #   (copy.py:494) after find_needle succeeds.
    # The remaining crash point - `_remote_expand_user(dest)`'s
    # `user_path.startswith('~')` (copy.py:511) - fires only after the src
    # lookup succeeded, so it is checked after inline_copy_source_content
    # (copy_dest_expand_failure below): a missing src fails with Ansible's
    # "Could not find or access" wording first, exactly like real.
    private def copy_literal_type_failure(task : Task, params : Hash(String, String)) : JSON::Any?
      return nil unless task.module_name == "ansible.builtin.copy"
      if params.has_key?("content")
        if Krikri.python_param_truthy?(params["dest"]?) &&
           (native = Krikri.non_string_scalar(params["dest"]?))
          return literal_attribute_crash_result(native, "endswith")
        end
        return nil
      end
      return nil if remote_src_param?(params)
      if (native = Krikri.non_string_scalar(params["src"]?))
        return literal_attribute_crash_result(native, "endswith")
      end
      if Krikri.python_param_truthy?(params["dest"]?) &&
         (native = Krikri.non_string_scalar(params["dest"]?)) &&
         (src = params["src"]?) && !src.empty? && Dir.exists?(src)
        return literal_attribute_crash_result(native, "endswith")
      end
      nil
    end

    # The last of real copy.py's non-string-literal crash points
    # (`_remote_expand_user`, copy.py:511) - reached only when the src
    # resolved fine, so it runs after inline_copy_source_content's own
    # missing-src failure would have returned. See
    # copy_literal_type_failure for the message shapes.
    #
    # `remote_src: true` never reaches it: Ansible's copy.py hands the whole
    # task to the copy MODULE on the target the moment remote_src is
    # truthy (the `elif remote_src:` branch right after the content
    # tempfile), so the local path is never walked and no dest/src
    # attribute is ever touched. That module's own argspec validation is
    # then the FIRST thing to inspect the literal - a wrong-type bool or
    # an unsupported key fails there, and a dest that survives
    # validation is coerced by the module's `type: path` spec
    # (check_type_path -> str()) rather than crashing. Live-verified vs
    # 2.19.11: `remote_src: true` + `dest: 89` + `backup: notabool`
    # reports the bool error, while the same dest with remote_src absent
    # or false crashes with startswith.
    private def copy_dest_expand_failure(task : Task, params : Hash(String, String)) : JSON::Any?
      return nil unless task.module_name == "ansible.builtin.copy"
      return nil if remote_src_param?(params)
      return nil unless Krikri.python_param_truthy?(params["dest"]?)
      return nil unless native = Krikri.non_string_scalar(params["dest"]?)
      literal_attribute_crash_result(native, "startswith")
    end

    private def literal_attribute_crash_result(native : JSON::Any, attribute : String) : JSON::Any
      literal_crash_result("'#{Krikri.python_scalar_type_name(native)}' object has no attribute '#{attribute}'")
    end

    # Ansible's assemble action plugin, on the branch that assembles the
    # fragments on the controller (remote_src present and falsy, see
    # assemble_action_local_path?), expands the destination's user path
    # itself - `dest = self._remote_expand_user(dest)` - right after the
    # fragments are assembled and BEFORE it hands the task to the copy
    # module, and that expand calls path.startswith('~') on the value. A
    # non-string YAML literal dest therefore crashes the ACTION plugin
    # there, and that crash is what the task reports: the copy module's
    # own spec checks (a typo'd option, a wrong-typed option) never run,
    # so krikri must not let them report first (live-verified vs 2.19.11:
    # an int dest crashes with '_AnsibleTaggedInt' and a bool one with
    # plain 'bool' - and EVERY non-string literal crashes, 0 and false
    # included, because the action's presence check is a None check, not a
    # truthiness one). It fires only after the src lookup, the isdir check
    # and the fragment assembly, which is why this runs after
    # stage_assemble_dir and not next to the src crash above.
    private def assemble_dest_expand_failure(task : Task, params : Hash(String, String)) : JSON::Any?
      return nil unless task.module_name == "ansible.builtin.assemble"
      return nil unless assemble_action_local_path?(params)
      dest = params["dest"]?
      return nil if dest.nil? || dest == Krikri::NONE_SENTINEL
      return nil unless native = Krikri.non_string_scalar(dest)
      literal_attribute_crash_result(native, "startswith")
    end

    # os.path.expanduser(os.fspath(x)) on a non-string YAML literal - the
    # crash Ansible's unarchive action hits on a non-string src
    # (`source = os.path.expanduser(source)`, unarchive.py action, both
    # remote_src flavors, live-verified vs 2.19.11).
    private def literal_expanduser_crash_result(native : JSON::Any) : JSON::Any
      literal_crash_result("expected str, bytes or os.PathLike object, not #{Krikri.python_scalar_type_name(native)}")
    end

    private def literal_crash_result(bare : String) : JSON::Any
      JSON.parse({
        "changed"               => false,
        "failed"                => true,
        "msg"                   => "Task failed: #{bare}",
        "_ansible_error_detail" => bare,
        "_ansible_action_level" => true,
      }.to_json)
    end

    # convert_bool()-shaped truthiness for a param Ansible reads through
    # boolean(..., strict=False): a parser-marked non-string literal
    # contributes its NATIVE truthiness (1/1.0/true truthy, 0/0.0/false
    # falsy), a plain string the boolean-literal spelling check the plain
    # wire always used.
    private def ansible_boolean_param?(value : String?) : Bool
      return false unless value
      return Krikri.python_param_truthy?(value) if Krikri.non_string_scalar(value)
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end

    # Ansible's unarchive/assemble action plugins crash on non-string YAML
    # literal args (the parser marks those; see NON_STRING_PARAM_PREFIX)
    # at their own controller-side touch points, before the module or the
    # "dest must be an existing dir"/isdir checks - all live-verified vs
    # 2.19.11:
    # - unarchive creates (when truthy): _remote_expand_user(creates)'s
    #   `startswith('~')` - "'<type>' object has no attribute 'startswith'";
    # - unarchive dest: the same _remote_expand_user call (unarchive.py:66),
    #   firing for EVERY non-string literal dest, falsy ones included (the
    #   presence check is a None check, not a truthiness check);
    # - unarchive src: `os.path.expanduser(source)` right after the dest
    #   expand (unarchive.py:67) - "expected str, bytes or os.PathLike
    #   object, not <type>", in BOTH remote_src flavors;
    # - assemble src (only when the action takes its controller-side
    #   branch - remote_src present and boolean(strict=False) falsy, see
    #   assemble_action_local_path?; the default delegates to the module,
    #   whose path-typed spec coerces the literal to text instead):
    #   _find_needle(src)'s startswith.
    # Checked before the src staging paths so the marker text can never
    # leak into a Searched-in list or an upload path; the src/dest presence
    # guards keep Ansible's ordering when either is genuinely absent (real
    # fails "src (or content) and dest are required" / "src and dest are
    # required" before touching any of them), as does skipping the
    # unarchive checks when the copy/remote_src mutual exclusion applies.
    private def unarchive_assemble_literal_type_failure(task : Task, params : Hash(String, String)) : JSON::Any?
      if task.module_name == "ansible.builtin.unarchive"
        return nil unless params.has_key?("src") && params.has_key?("dest")
        return nil if params.has_key?("copy") && params.has_key?("remote_src")
        if ansible_boolean_param?(params["creates"]?) && (native = Krikri.non_string_scalar(params["creates"]?))
          return literal_attribute_crash_result(native, "startswith")
        end
        if native = Krikri.non_string_scalar(params["dest"]?)
          return literal_attribute_crash_result(native, "startswith")
        end
        if native = Krikri.non_string_scalar(params["src"]?)
          return literal_expanduser_crash_result(native)
        end
        return nil
      end
      if task.module_name == "ansible.builtin.assemble"
        return nil unless params.has_key?("src") && params.has_key?("dest")
        return nil unless assemble_action_local_path?(params)
        if native = Krikri.non_string_scalar(params["src"]?)
          return literal_attribute_crash_result(native, "startswith")
        end
      end
      nil
    end

    # The assemble action's controller-side branch: remote_src is PRESENT
    # and boolean(remote_src, strict=False) is not True - falsy spellings,
    # invalid spellings ('timjjr'), explicit None and non-1 native numbers
    # all land here (see Krikri.lenient_boolean_true? for the exact
    # predicate, live-verified vs 2.19.11). An ABSENT remote_src takes the
    # module branch (the action's default is the string 'yes').
    private def assemble_action_local_path?(params : Hash(String, String)) : Bool
      return false unless params.has_key?("remote_src")
      !Krikri.lenient_boolean_true?(params["remote_src"]?)
    end

    private def remote_src_param?(params : Hash(String, String)) : Bool
      # Ansible's own predicate for the action plugin's remote_src branch
      # (copy.py:422): boolean(value, strict=False) - the full
      # BOOLEANS_TRUE spelling list (y/yes/on/1/true/t and the native
      # true/1/1.0), everything else - invalid spellings, explicit None,
      # other natives - falsy. Previously a narrower four-spelling
      # string check that missed both the 'y'/'t' spellings and the
      # parser's marked non-string literal form of `remote_src: true`.
      Krikri.lenient_boolean_true?(params["remote_src"]?)
    end

    # Ansible's add_host: non-string YAML literal args (the parser marks
    # those; see NON_STRING_PARAM_PREFIX) crash the run at two different
    # stages, both live-verified vs 2.19.11:
    #
    # - groups/group/groupname (real precedence, first present wins): a
    #   TRUTHY non-list/non-string fails the task inside the action
    #   plugin with AnsibleActionFail "Groups must be specified as a
    #   list." - an un-prefixed fatal msg plus a two-segment [ERROR]
    #   block whose cause carries the failing param value's own Origin
    #   (see emit_task_error_block's _ansible_fail_param branch). A falsy
    #   literal (0/0.0/false) is skipped by the action's `if groups:`
    #   truthiness check entirely.
    # - name/hostname/host (real precedence, the FIRST PRESENT key wins -
    #   args.get returns a present key's value even when it is None or
    #   ""): a None value - the key absent everywhere, a YAML `name:`
    #   with no value (the parser wires literal nulls as NONE_SENTINEL),
    #   or a whole-span null template - fails the task inside the action
    #   plugin with AnsibleActionFail "name, host or hostname needs to be
    #   provided" BEFORE the groups handling, an un-prefixed fatal msg
    #   plus the plain "Task failed: <msg>" chain (no "Module failed."
    #   segment, no "Action failed." one either - a raised
    #   AnsibleActionFail, unlike group_by's returned failed result). An
    #   empty-STRING value passes the action's `is None` check and aborts
    #   the whole run at inventory.add_host with "Invalid empty host name
    #   provided:" (rc 1, no recap), exactly like the falsy non-string
    #   literals ("Invalid empty host name provided: 0") and the truthy
    #   non-string ones ("Invalid host name supplied, expected a string
    #   but got <class 'ansible.module_utils._internal._datatag
    #   ._AnsibleTaggedInt'> for 5") below.
    # - groups/group/groupname (real precedence, first present wins): a
    #   TRUTHY non-list/non-string fails the task inside the action
    #   plugin with AnsibleActionFail "Groups must be specified as a
    #   list." - an un-prefixed fatal msg plus a two-segment [ERROR]
    #   block whose cause carries the failing param value's own Origin
    #   (see emit_task_error_block's _ansible_fail_param branch). A falsy
    #   literal (0/0.0/false) is skipped by the action's `if groups:`
    #   truthiness check entirely. A LIST whose MEMBERS aren't all
    #   strings crashes the member loop's `group_name.strip()` at the
    #   first non-string member - see list_member_attribute_crash.
    #   The groups failure precedes the name crash (action stage before
    #   result processing), and the name failure precedes the groups
    #   failure (Ansible's name check is the first raise in the action).
    private def add_host_literal_type_failure(task : Task, params : Hash(String, String)) : JSON::Any?
      return nil unless task.module_name == "ansible.builtin.add_host" || task.module_name == "add_host"

      effective_name : String? = nil
      {"name", "hostname", "host"}.each do |name_key|
        if raw = params[name_key]?
          effective_name = raw
          break
        end
      end

      if effective_name.nil? || effective_name == Krikri::NONE_SENTINEL
        return Krikri.mark_failed_key_order(JSON.parse({
          "changed"               => false,
          "failed"                => true,
          "msg"                   => "name, host or hostname needs to be provided",
          "_ansible_action_level" => true,
        }.to_json), FAILED_KEY_ORDER_MSG_FIRST)
      end

      {"groupname", "groups", "group"}.each do |group_key|
        raw = params[group_key]? || next
        if raw == Krikri::NONE_SENTINEL
          next
        end
        if Krikri.non_string_scalar(raw)
          next unless Krikri.python_param_truthy?(raw)
          return Krikri.mark_failed_key_order(JSON.parse({
            "changed"               => false,
            "failed"                => true,
            "msg"                   => "Groups must be specified as a list.",
            "_ansible_action_level" => true,
            "_ansible_error_detail" => "Groups must be specified as a list.",
            "_ansible_fail_param"   => group_key,
          }.to_json), FAILED_KEY_ORDER_MSG_FIRST)
        end
        if bare = list_member_attribute_crash(raw, "strip")
          return literal_crash_result(bare)
        end
      end

      if native = Krikri.non_string_scalar(effective_name)
        if Krikri.python_param_truthy?(effective_name)
          STDERR.puts "[ERROR]: Invalid host name supplied, expected a string but got <class '#{Krikri.python_scalar_class_path(native)}'> for #{Krikri.python_str_scalar(native)}".colorize(:red)
        else
          STDERR.puts "[ERROR]: Invalid empty host name provided: #{Krikri.python_str_scalar(native)}".colorize(:red)
        end
        # Same Process.exit reasoning as abort_invalid_meta_action: this
        # runs inside the executor's per-task paths, which swallow `exit`'s
        # ExitException; both streams are flushed explicitly first.
        STDOUT.flush
        STDERR.flush
        Process.exit(1)
      end
      if effective_name.empty?
        # Ansible's message carries the name's Python str() after the colon
        # only when there IS one - an empty string renders the bare colon
        # with no trailing space (live-verified byte-for-byte vs 2.19.11).
        STDERR.puts "[ERROR]: Invalid empty host name provided:".colorize(:red)
        STDOUT.flush
        STDERR.flush
        Process.exit(1)
      end
      nil
    end

    # Ansible's group_by/add_host action plugins iterate a YAML list arg's
    # members with plain string ops (group_by's
    # `[name.replace(' ', '-') for name in parent_groups]`, add_host's
    # `group_name.strip()`), so a non-string MEMBER crashes the action -
    # "'<type>' object has no attribute '<attr>'" - at the FIRST such
    # member in list order (live-verified vs 2.19.11 for
    # int/float/bool/nil/dict/list members on both params). Members reach
    # these hooks as either the parser's JSON array wire (dict members
    # present - native member types preserved in the JSON itself) or its
    # comma-joined wire with NON_STRING_MEMBER_PREFIX-marked non-string
    # members. Returns the bare crash message, or nil when every member
    # is a string (or the value is a plain string that merely looks like
    # a list - the same JSON-decode ambiguity the add_host plugin's own
    # parse_group_names already accepts).
    private def list_member_attribute_crash(raw : String, attribute : String) : String?
      if raw.starts_with?('[') && (parsed = (JSON.parse(raw) rescue nil)) && (items = parsed.as_a?)
        items.each do |item|
          unless item.as_s?
            return "'#{Krikri.python_value_type_name(item)}' object has no attribute '#{attribute}'"
          end
        end
        return nil
      end
      return nil unless raw.includes?(Krikri::NON_STRING_MEMBER_PREFIX)
      raw.split(',').each do |part|
        next if part.empty? || !part.starts_with?(Krikri::NON_STRING_MEMBER_PREFIX)
        if native = Krikri.non_string_member_scalar(part)
          return "'#{Krikri.python_value_type_name(native)}' object has no attribute '#{attribute}'"
        end
      end
      nil
    end

    # Data-driven module argument validation (see ArgspecValidator): the
    # failing result JSON for this task's module args, or nil when
    # validation passes or does not apply. Ansible runs these checks
    # inside the module's own AnsibleModule init - i.e. after the action
    # plugin stage, before any module-side file access - which is exactly
    # where the two callers of this hook sit.
    # Core modules whose real module source declares
    # supports_check_mode=False (and whose plugin mirrors the skip).
    NO_CHECK_MODE_MODULES = %w[
      ansible.builtin.uri ansible.builtin.wait_for ansible.builtin.tempfile
      community.mysql.mysql_query community.mysql.mysql_variables
    ]

    private def argspec_validation_result(
      task : Task,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
      action_level_only : Bool,
      check_mode : Bool = false,
    ) : JSON::Any?
      # Role-private library/ modules and the py_module runner run real
      # Python whose spec we don't know - nothing to validate against.
      return nil if task.unavailable_module
      action_name = task.action_name || task.module_name
      failure = ArgspecValidator.validate(action_name, task.module_name, params, vars_context)
      return nil unless failure
      # The pre-action hook (action_level_only) takes only the
      # action-plugin-level failures; the post-action hook takes only
      # the module-level ones.
      return nil if failure.action_level? != action_level_only
      # Ansible's copy action - which template: delegates to - short-circuits
      # in check mode the moment the checksums differ (copy.py:288-293:
      # "result['changed'] = True; return result"), so the copy module's
      # own spec never rejects the template-only leftovers under --check
      # (live-verified vs 2.19.11). The module-level failures of the
      # template: delegation are therefore skipped in check mode; the
      # action-level ones (src/dest presence) still fire, exactly like
      # Ansible's action plugin. A truthy remote_src is the one exception:
      # that branch dispatches the copy module right away (copy.py:466),
      # so its spec - unsupported parameters included - does run under
      # --check too.
      return nil if check_mode && !action_level_only &&
                    task.module_name == "ansible.builtin.template" && !remote_src_param?(params)
      # Modules that do not support check mode never reach their
      # AnsibleModule init under --check (2.19's action layer raises
      # AnsibleActionSkip "This action (...) does not support check mode."
      # before any argument validation - live-verified vs 2.19.11: uri
      # with an invalid status_code element SKIPS under --check instead
      # of failing), so their module-level spec checks are skipped too.
      return nil if check_mode && !action_level_only && NO_CHECK_MODE_MODULES.includes?(task.module_name)
      # ... and outside check mode the copy MODULE only runs when the
      # bytes actually have to move. See copy_module_never_runs?.
      return nil if !action_level_only && copy_module_never_runs?(task, params, check_mode)

      # Ansible's fail_json shape for an argument-spec rejection, live-verified
      # vs ansible-core 2.19.11: the module's own kwargs lead (a copy
      # module's always-present diff:[], then failed+msg), then the
      # controller backfills changed, then exception
      # ("(traceback unavailable)") - the same order PluginResult's own
      # failed_default_order emits. Built in that order here rather than
      # insertion-ordered by assignment.
      result = {} of String => JSON::Any
      # copy's module-level failure keeps Ansible's always-present "diff" key
      # (an empty LIST): a registered failed copy shows "diff": [] for the
      # argspec case too (live-verified vs 2.19.11) - the plugin's own
      # post-processing adds it to every copy result that reaches the
      # module binary, so the controller-simulated ones need it here.
      result["diff"] = JSON::Any.new([] of JSON::Any) if task.module_name == "ansible.builtin.copy" && !action_level_only
      result["failed"] = JSON::Any.new(true)
      result["msg"] = JSON::Any.new(failure.msg)
      # copy/template: Ansible's action plugin computes the source SHA1
      # before the module runs and merges it into the failed result, so
      # the fatal dump carries "checksum" for these two modules - but
      # only where Ansible's action plugin actually reaches the
      # checksum-merging tail (live-verified vs 2.19.11): template:'s
      # delegation reaches it unless the delegated copy took ITS
      # remote_src branch, which returns the module result directly
      # (copy.py:466-468) and never adds a checksum - only the _copy_file
      # path (content:, or a controller-side src with remote_src falsy)
      # does. (Only for MODULE-level failures: the action plugin's own
      # required-argument checks fail before it computes any checksum.)
      if !action_level_only &&
         ((task.module_name == "ansible.builtin.template" && !remote_src_param?(params)) ||
         (task.module_name == "ansible.builtin.copy" &&
         (params.has_key?("content") || !remote_src_param?(params))))
        if checksum = argspec_source_checksum(params)
          result["checksum"] = JSON::Any.new(checksum)
        end
      end
      # A controller-side failure with no changed key at all (the
      # omit_changed shape) skips the backfill entirely - see
      # PluginResult#omit_changed.
      unless failure.omit_changed?
        result["changed"] = JSON::Any.new(false)
        result["exception"] = JSON::Any.new("(traceback unavailable)")
      end
      JSON.parse(result.to_json)
    end

    # Whether Ansible's copy ACTION plugin leaves the copy MODULE unexecuted
    # for this task - in which case the copy module's own argument spec
    # (its `type: bool` conversions, its unsupported-parameter check)
    # never runs and can never fail the task. The two ways that happens
    # (copy.py, live-verified vs 2.19.11):
    #
    # - remote_src is truthy: the opposite - the action plugin hands the
    #   whole task straight to the module (copy.py:466), so the module
    #   always runs and its spec always applies;
    # - the action plugin's own _copy_file decides nothing has to be
    #   transferred: under --check it returns changed=True as soon as the
    #   checksums differ (copy.py:288-293), and when the destination
    #   already holds the source's content it skips the transfer
    #   altogether and dispatches ansible.legacy.file - with copy's
    #   copy-only options (backup, local_follow, remote_src, validate,
    #   checksum, directory_mode, content, src) STRIPPED, so they are
    #   never validated either.
    #
    # The checksum comparison is only made when both paths are readable
    # on the controller (a local connection, or a destination the
    # executor can stat); for a genuinely remote destination the branch
    # is left undecided, which keeps the module's spec applied.
    private def copy_module_never_runs?(task : Task, params : Hash(String, String), check_mode : Bool) : Bool
      return false unless {"ansible.builtin.copy", "ansible.builtin.template"}.includes?(task.module_name)
      return false if remote_src_param?(params)
      return true if check_mode
      return false if params.has_key?("content")
      src = params["src"]?
      dest = params["dest"]?
      return false unless src && dest && Krikri.non_string_scalar(src).nil? && Krikri.non_string_scalar(dest).nil?
      return false unless File.file?(src) && File.file?(dest)
      Digest::SHA1.hexdigest(File.read(src)) == Digest::SHA1.hexdigest(File.read(dest))
    end

    # SHA1 of the source content a copy/template task would deploy - the
    # value Ansible's copy action plugin puts in its result (live-verified:
    # sha1 of the content string, or of the source FILE's bytes when src
    # is a controller file; nothing when src is remote or missing).
    private def argspec_source_checksum(params : Hash(String, String)) : String?
      if content = params["content"]?
        return Digest::SHA1.hexdigest(content)
      end
      # A truthy remote_src (in whatever spelling, marked literal
      # included) means the action plugin handed the task to the module
      # without ever computing a local checksum.
      return nil if Krikri.lenient_boolean_true?(params["remote_src"]?)
      src = params["src"]?
      return nil unless src && File.exists?(src) && !File.directory?(src)
      Digest::SHA1.hexdigest(File.read(src))
    end

    # Adds stdout_lines/stderr_lines (Ansible behavior - each module
    # that has stdout/stderr sets these itself; krikri derives them
    # centrally here instead) to a plugin result. Shared by register_result
    # below (for later tasks referencing the registered var) AND
    # apply_changed_failed_when (executor_run_loop.cr) building its own
    # eval_context for the SAME task's own changed_when:/failed_when: -
    # those must see the identical augmented shape, not the plugin's raw
    # result, or a changed_when: like buluma.netdata's own `... not in
    # netdata_requirements_install.stderr_lines` raises "object of type
    # 'dict' has no attribute 'stderr_lines'" even though a LATER task
    # referencing the same registered var would have seen it fine.
    private def with_command_lines_augmented(result : JSON::Any, omit_command_lines : Bool = false) : JSON::Any
      result_hash = result.as_h.dup

      # A result carrying the _ansible_omit_command_lines marker (pause -
      # see the pause action plugin's own comment) opts out: Ansible's pause
      # module has stdout/stderr but never derives *_lines from them
      # (live-verified vs 2.19.11 registered pause shape). register_result
      # strips the marker with every other _ansible_* key BEFORE calling
      # here, so its presence is captured and passed in as the flag; the
      # has_key? check covers call sites that still see the unstripped
      # result (the changed_when/failed_when eval context).
      return JSON::Any.new(result_hash) if omit_command_lines || result_hash.has_key?("_ansible_omit_command_lines")

      if stdout = result_hash["stdout"]?.try(&.as_s)
        stdout_lines = ansible_splitlines(stdout).map { |line| JSON::Any.new(line) }
        result_hash["stdout_lines"] = JSON::Any.new(stdout_lines)
      end

      if stderr = result_hash["stderr"]?.try(&.as_s)
        stderr_lines = ansible_splitlines(stderr).map { |line| JSON::Any.new(line) }
        result_hash["stderr_lines"] = JSON::Any.new(stderr_lines)
      end

      JSON::Any.new(result_hash)
    end

    # Register task result as a variable
    private def register_result(host : Host, register_name : String, result : JSON::Any) : Nil
      # Strip private `_ansible_*` result keys before register: - real
      # Ansible never lets them through (live-verified: assert:'s own
      # `_ansible_verbose_always` is absent from the registered var), and
      # the assert plugins' `_ansible_quiet` display marker is likewise
      # controller-internal, not part of the registered shape.
      #
      # `invocation` is stripped here too, generically: ansible-core's
      # strategy plugin (strategy/__init__.py, "register final results"
      # block) deletes a top-level `invocation` key from the clean copy it
      # registers. Round 813375 (galaxyproject.pulsar) pinned the exact
      # split this mirrors: a NON-looped register never exposes
      # `invocation` (stripped here), while each per-item entry inside a
      # LOOPED+registered task's `results[]` keeps its own `invocation`
      # intact (the strategy strip only touches the top-level dict) - so
      # this must stay out of the loop aggregation path in
      # executor_loops.cr.
      result_hash = result.as_h.dup
      apply_failed_key_order(result_hash)
      # Capture the pause opt-out marker BEFORE the _ansible_* strip below
      # removes it (see with_command_lines_augmented's comment).
      omit_command_lines = result_hash.has_key?("_ansible_omit_command_lines")
      result_hash.reject! { |key, _| key.starts_with?("_ansible_") }
      result_hash.delete("invocation")
      registered = with_command_lines_augmented(JSON::Any.new(result_hash), omit_command_lines: omit_command_lines)
      @registered_vars[host.name][register_name] = registered
      # Write-time unsafe marking - the per-task context build marks these
      # stores too, but a host that never executes again would otherwise
      # never get its write marked, and a cross-host hostvars read of this
      # result would re-render its text on the reading host (see
      # VarSubstitutor.add_resolved_var_name's comment).
      UnsafeValues.mark_value(registered)
      VarSubstitutor.add_resolved_var_name(host.name, register_name)
      @hv_generation += 1
    end

    # Applies the real key order a controller-side action failure's
    # REGISTERED result carries (see Krikri::FAILED_KEY_ORDER_DEFAULT):
    # the order the action's builder marked the result with, plus the
    # `exception: "(traceback unavailable)"` key Ansible's fail_json adds on
    # every failure - including these, which krikri's own result builders
    # left out. Applied here, at the single point every registered result
    # passes through, so no individual builder has to know the rule.
    private def apply_failed_key_order(hash : Hash(String, JSON::Any)) : Nil
      order = hash["_ansible_key_order"]?.try(&.as_a) || return
      hash["exception"] = JSON::Any.new("(traceback unavailable)") unless hash.has_key?("exception")
      # A result whose display shape omits `changed` (debug:'s own
      # fatalization failure) but whose registered shape carries it - see
      # the `_ansible_register_changed` marker.
      if hash.delete("_ansible_register_changed")
        hash["changed"] = JSON::Any.new(false)
      end
      ordered = Hash(String, JSON::Any).new
      order.each do |entry|
        key = entry.as_s?
        ordered[key] = hash[key] if key && hash.has_key?(key)
      end
      hash.each { |key, value| ordered[key] = value unless ordered.has_key?(key) }
      hash.clear
      ordered.each { |key, value| hash[key] = value }
    end

    # Run all notified handlers
  end
end
