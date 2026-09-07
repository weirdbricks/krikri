require "./executor"

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
      substitutor = VarSubstitutor.new(vars: base, host_name: host.name)

      @vars_files.each do |candidates|
        candidates.each do |raw|
          rendered = (substitutor.substitute(raw) rescue raw)
          path = File.expand_path(rendered, @vars_files_dir)
          next unless File.exists?(path)

          begin
            parsed = YAML.parse(File.read(path))
            if hash = parsed.as_h?
              hash.each { |key, value| merged[key.to_s] = JSON.parse(value.to_json) }
            end
          rescue
            # A vars file that will not parse is skipped rather than
            # taking the run down - real ansible-playbook likewise does
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
      options.each do |option_name, spec|
        # Real Ansible templates the ENTIRE argument spec - `default:`
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
          # A spec default stands in for a missing option during
          # validation (real Ansible applies it before type-checking);
          # only an option with NO default can be "missing required".
          if resolved_default
            value = resolved_default
          else
            errors << "missing required argument: #{option_name}" if spec["required"]?.try(&.as_bool?) == true
            next
          end
        end

        if declared_type = spec["type"]?.try(&.as_s?)
          unless argument_type_matches?(value, declared_type)
            errors << "argument '#{option_name}' is of type #{json_type_name(value)} and we were unable to convert to #{declared_type}"
          end
        end
      end

      if errors.empty?
        puts "ok: [#{host.name}]".colorize(:green)
        @results[host.name]["ok"] += 1
      else
        puts "failed: [#{host.name}]".colorize(:red)
        puts "  Message: Validation of arguments failed:\n    #{errors.join("\n    ")}".colorize(:red)
        # Same ignore_errors: stats fix as finish_include_vars_failure -
        # an ignored failure counts as ok+ignored, not failed.
        if task.ignore_errors?
          @results[host.name]["ok"] += 1
          @results[host.name]["ignored"] += 1
        else
          @results[host.name]["failed"] += 1
          @halted_hosts.add(host.name)
        end
      end
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
          # True) - real ansible-core's own argument-spec validator
          # accepts a bool value for a declared int/float param on that
          # basis. dev-sec mysql_hardening's own argument_specs.yml
          # declares mysql_hardening_skip_show_database as `type: int,
          # default: 1` while defaults/main.yml sets it to the literal
          # boolean `true` - a real (if sloppy) mismatch in the role
          # itself that real ansible-playbook tolerates via this exact
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

    # Resolve with_fileglob patterns (if any) against the control host's
    # filesystem, after substituting any {{ vars }} in the pattern.
    private def expression_evaluator_for(vars_context : Hash(String, JSON::Any)) : VariableSubstitutor::ExpressionEvaluator
      VariableSubstitutor::ExpressionEvaluator.new(vars_context)
    end

    # Python's own type name for a resolved loop-source value, matching
    # real Ansible's own error wording exactly ("not 'NoneType'", "not
    # 'str'"). Only 'NoneType' and 'str' were live-verified (round174
    # matrix scenarios 11a/11c); 'int'/'float'/'bool'/'dict' are inferred
    # from the same CPython type()/__name__ convention, not independently
    # verified against a real ansible-playbook run.
    private def python_type_name(value : JSON::Any) : String
      case value.raw
      when Nil     then "NoneType"
      when Bool    then "bool"
      when Int64   then "int"
      when Float64 then "float"
      when Hash    then "dict"
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

      register_result(host, register_name, JSON.parse({
        "changed"     => false,
        "skipped"     => true,
        "skip_reason" => "Conditional result was False",
      }.to_json))
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
      if key.nil? || key.empty?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "missing required argument: key"}.to_json)
      end

      inventory = @inventory
      unless inventory
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "group_by: no inventory available in this context"}.to_json)
      end

      group_names = key.split(",").map(&.strip).reject(&.empty?)
      parent_names = params["parents"]?.try(&.split(",").map(&.strip).reject(&.empty?)) || [] of String

      changed = false
      group_names.each do |group_name|
        group = inventory.get_or_create_group(group_name)
        unless group.hosts.has_key?(host.name)
          group.add_host(host)
          changed = true
        end
        parent_names.each { |parent_name| inventory.get_or_create_group(parent_name).add_child(group_name) }
      end

      JSON.parse({"changed" => changed, "failed" => false, "msg" => "", "groups" => group_names}.to_json)
    end

    # set_stats: - same "no uploaded plugin binary" category as
    # group_by:/reboot: above. Writes into CustomStats (a process-wide
    # accumulator, not scoped to this TaskExecutor instance - real
    # Ansible's own custom-stats block covers the WHOLE run, and
    # krikri-playbook.cr constructs a fresh TaskExecutor per play).
    private def execute_reboot(params : Hash(String, String), exec_host : Host, vars_context : Hash(String, JSON::Any),
                               check_mode : Bool = @check_mode) : JSON::Any
      return JSON.parse({"changed" => true, "failed" => false, "msg" => "Would have rebooted"}.to_json) if check_mode

      if PluginManager.local_connection?(exec_host, vars_context)
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "ansible.builtin.reboot is not supported over a local connection (would reboot the controller itself)",
        }.to_json)
      end

      reboot_timeout = params["reboot_timeout"]?.try(&.to_i?) || 600
      connect_timeout = params["connect_timeout"]?.try(&.to_i?) || 5
      pre_reboot_delay = params["pre_reboot_delay"]?.try(&.to_i?) || 2
      post_reboot_delay = params["post_reboot_delay"]?.try(&.to_i?) || 0
      test_command = params["test_command"]?.try { |v| v.empty? ? nil : v } || "whoami"
      reboot_command = params["reboot_command"]?.try { |v| v.empty? ? nil : v } || "systemctl reboot"

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
      if issue_result && issue_result[:exit_code] != 0 && issue_result[:exit_code] != 255 && !issue_result[:stderr].empty?
        return JSON.parse({
          "changed" => false,
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
          "failed"  => true,
          "msg"     => "Timed out waiting for #{connection_host} to come back after reboot (#{reboot_timeout}s)",
        }.to_json)
      end

      sleep post_reboot_delay.seconds if post_reboot_delay > 0

      JSON.parse({
        "changed"  => true,
        "failed"   => false,
        "rebooted" => true,
        "msg"      => "Reboot complete",
      }.to_json)
    end

    # Override a task's own changed/failed verdict with changed_when:/
    # failed_when:, evaluated against vars_context plus the task's own result
    # (made available under its own register: name, mirroring real Ansible -
    # a bare literal like "false" needs no register: at all; referencing a
    # result field like "result.rc" does). Same substitute-then-evaluate
    # pipeline as when_condition/until_condition.
    private def finish_single_task(task : Task, host : Host, result : JSON::Any, fact_host : Host = host) : Nil
      result = debug_if_requested(task, host, result)
      merge_ansible_facts(fact_host, result, task.module_name.ends_with?("set_fact"))

      if register_name = task.register
        register_result(host, register_name, result) unless register_name.empty?
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
      # real Ansible correctly shows these as `skipping:` and counts
      # them under `skipped=`, not `ok=`.
      if result["skipped"]?.try(&.as_bool) == true
        puts "skipping: [#{host.connection_host}]".colorize(:cyan)
        @results[host.name]["skipped"] += 1
        return
      end

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_handlers(task, host, notify_list)
      end

      if @adhoc
        ResultDisplay.display_adhoc_result(host, result)
      else
        ResultDisplay.display_result(host, result, @diff_mode, ignore_errors: task.ignore_errors?, no_log: task.no_log?)
      end
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors?)
      halt_if_failed(task, host, failed)
    end

    # Marks `host` as halted (no further tasks in this play run for it)
    # when `failed` and the task didn't opt out via ignore_errors:.
    private def print_skipped_tasks(tasks : Array(Task), host : Host) : Nil
      tasks.each do |nested_task|
        # A nested block is transparent - like real Ansible, it gets no
        # "TASK [...]" banner of its own, only its members do.
        if nested_task.block?
          print_skipped_tasks(nested_task.block_tasks || [] of Task, host)
          print_skipped_tasks(nested_task.always_tasks || [] of Task, host)
          next
        end

        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name

        # A static import_role: (Task#is_static_import), like a block:,
        # produces no result of its own when skipped either - real
        # Ansible's static splice means there's nothing here to show
        # "skipping" for (see is_static_import's own comment). The
        # included role's own tasks simply never got spliced in, with no
        # trace of the import_role: statement itself in the recap.
        if nested_task.include_role? && nested_task.is_static_import?
          next
        end

        puts "TASK [#{task_role_prefix(nested_task)}#{render_task_name_for_display(nested_task, host)}]".colorize(:white).bold
        puts "*" * 70
        puts "skipping: [#{connection_host}]".colorize(:cyan)
        # A skipped meta: task (e.g. a named meta: flush_handlers inside
        # a when:-false block) prints its "skipping:" line but is NOT
        # counted in the PLAY RECAP - real ansible-core ignores meta
        # tasks in stats entirely (0x0i.systemd: krikri skipped=9 vs
        # ansible skipped=8, the extra one being exactly this shape).
        unless nested_task.module_name == "_meta"
          @results[host.name]["skipped"] += 1
          register_skip_result(nested_task, host)
        end
        puts ""
      end
    end

    # Runs a block: task - the nested block_tasks, then rescue_tasks if the
    # block failed (recovering it if rescue succeeds), then always_tasks
    # unconditionally, re-applying the halt afterward if the block ultimately
    # failed (unrescued, or rescue itself failed, or always: introduced a new
    # failure) unless the block itself has ignore_errors:.
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
        return item unless raw.includes?("{{")

        # A raw value that's *exactly* one bare `{{ variable }}` span (no
        # surrounding text, no filter chain) resolves to the variable's
        # own native JSON type - matching real Ansible's own templating,
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
          # where real Ansible's actually-flattened, actually-scalar
          # `item` reported `ok`.
          begin
            evaluated = expression_evaluator_for(vars_context).evaluate(stripped[2..-3].strip)
            parsed = JSON.parse(evaluated)
            return parsed if parsed.as_a? || parsed.as_h?
          rescue
            # Not a list/dict, or not even valid JSON (an ordinary
            # rendered string) - fall through to the generic path below,
            # unchanged.
          end
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host_name)
        # strict: true - real Ansible templates the loop-source list itself
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
    private def inline_copy_source_content(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.copy"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase))
      return params if PluginManager.local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && src.starts_with?('/')

      # `Dir.exists?` raises (not just returns false) when src exists but
      # isn't readable by this process (a controller-local `copy: {src:
      # /root/...}` run as a non-root user - found live while
      # investigating an unrelated unarchive: bug). Real Ansible fails
      # just that ONE task with a permission error; this crashed the
      # entire binary. Falling through here lets the size check below
      # (already rescued) and the module's own src-open attempt produce
      # the normal per-task failure instead.
      is_directory = Dir.exists?(src) rescue false
      return stage_directory_copy_source(params, src, host, vars_context) if is_directory

      size = File.size(src) rescue nil
      return params unless size

      if size > INLINE_COPY_MAX_BYTES
        return stage_large_copy_source(params, src, host, vars_context)
      end

      begin
        content = File.read(src)
      rescue
        return params
      end

      resolved = params.dup
      resolved.delete("src")
      resolved["content"] = content
      # copy.cr's own handle_content_copy needs this to append the
      # right basename when dest: is an existing directory - see that
      # call site's own comment for the full "Is a directory" story.
      resolved["__original_src_basename"] = File.basename(src)
      resolved
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
    # matching real Ansible's own `copy:` behavior (it computes the
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
    # md5sums it in the same script, only if it exists.
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

      local_md5 = begin
        Digest::MD5.new.file(src).hexfinal
      rescue
        return nil
      end

      basename = File.basename(src)
      script = <<-SCRIPT
        p=#{shell_single_quote(dest)}
        [ -d "$p" ] && p="$p/#{basename.gsub("'", "'\\''")}"
        if [ -f "$p" ]; then md5sum "$p" | cut -d' ' -f1; else echo NOFILE; fi
        SCRIPT

      connection_host = PluginManager.get_connection_host(host, vars_context)
      result = SSHManager.exec_script(
        connection_host,
        host.user || "root",
        script,
        host.port,
        identity_file: vars_context["ansible_ssh_private_key_file"]?.try(&.as_s?)
      )
      return nil unless result[:exit_code] == 0 && result[:stdout].strip == local_md5

      resolved = params.dup
      resolved["__precomputed_match"] = "true"
      resolved["__precomputed_checksum"] = local_md5
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
      # it (real Ansible's own convention) to decide whether src's
      # contents land directly in dest or as a dest/<basename> subdir.
      resolved["src"] = src.ends_with?('/') ? "#{remote_tmp}/" : remote_tmp
      resolved["__cleanup_after_copy_dir"] = "true"
      resolved
    end

    # unarchive:'s own real Ansible default (remote_src: false, not
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
    private def stage_unarchive_remote_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.unarchive"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase))

      src = params["src"]?
      return params if src.nil? || src.empty?
      # URL sources are downloaded by the plugin itself - never stage.
      return params if src.starts_with?("http://") || src.starts_with?("https://")

      # A bare relative src: names a controller-side file in the role's
      # own files/ dir (real Ansible's unarchive action plugin searches
      # there via _find_needle, same convention copy:/template:/script:
      # use). Previously only an ABSOLUTE controller path was staged, so
      # `unarchive: src: "{{ package_name }}"` with
      # package_name="minio.tar.gz" handed the plugin a bare name that
      # failed remote_file_exists? - "Source 'minio.tar.gz' failed to
      # transfer" (wezhai.minio on Debian trixie, where tar exists and
      # the gap actually surfaces).
      unless src.starts_with?('/') && File.exists?(src)
        resolved_local = resolve_script_path(src, task)
        return params unless resolved_local
        src = resolved_local
      end
      return params unless File.exists?(src)

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

    # script:'s free-form `cmd` (or bare-string `_raw_params`, resolved to
    # `cmd` by RAW_COMMAND_MODULES parsing either way) is "<local path>
    # [args...]" - the path always names a file on the CONTROLLER, same
    # category of gap as unarchive:'s src: (see
    # #stage_unarchive_remote_src). Resolves the path against the
    # currently-executing role's own files/ dir first (real Ansible's own
    # script: action plugin searches there, same convention copy:/
    # template: use), then falls back to whatever's resolvable relative to
    # the controller's own cwd. A local connection needs the path resolved
    # (a role-relative name isn't meaningful relative to the plugin
    # process's own cwd otherwise) but never staged - the plugin process
    # already runs directly on the controller's filesystem in that case.
    private def stage_script_src(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.script"

      cmd = params["cmd"]? || params["_raw_params"]?
      return params unless cmd

      parts = cmd.strip.split(/\s+/, 2)
      local_path = parts[0]?
      return params if local_path.nil? || local_path.empty?
      rest = parts[1]?

      resolved_local = resolve_script_path(local_path, task)
      return params unless resolved_local

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
    private def stage_assemble_dir(task : Task, params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : Hash(String, String)
      return params unless task.module_name == "ansible.builtin.assemble"
      return params if ["true", "yes", "1", "on"].includes?(params["remote_src"]?.try(&.downcase)) || params["remote_src"]?.nil?
      return params if PluginManager.local_connection?(host, vars_context)

      src = params["src"]?
      return params unless src && Dir.exists?(src)

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

    # Build plugin configuration
    private def build_plugin_config(
      task : Task,
      host : Host,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
      become_user : String? = task.become_user,
    ) : String
      # Add check_mode and diff_mode to params
      final_params = params.dup
      final_params["check_mode"] = resolve_task_check_mode(task, vars_context).to_s
      final_params["diff_mode"] = @diff_mode.to_s
      # debug.cr's own verbosity: gate reads this back out - previously
      # never set at all, so a role's `debug: ... verbosity: 2` always
      # compared against a hardcoded 0 regardless of real -v/-vv/-vvv
      # flags (see debug.cr's own comment on `_verbosity`).
      final_params["_verbosity"] = @verbosity.to_s

      # environment: - substituted here (once, with the same vars_context
      # every other param already uses) and forwarded as a single JSON
      # blob under a reserved param key; BasePlugin#remote_exec/#local_exec
      # read it back out and prefix whatever command the plugin shells out
      # with the equivalent `export K=V; ...` - applies uniformly to every
      # plugin that shells out (command/shell/apt/systemctl/...) rather
      # than needing separate wiring per plugin.
      if task_env = task.environment
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_env = task_env.transform_values { |v| substitutor.substitute(v) }
        final_params["_environment"] = substituted_env.to_json
      end

      # Only debug:/assert: actually read the vars context inside the
      # plugin process (BasePlugin itself only ever pulls 3 connection
      # keys out of it - see PluginManager::NEEDS_FULL_VARS). Everyone
      # else gets just those 3 keys instead of the full context, which
      # for a typical templating-heavy task is tens to hundreds of KB of
      # JSON (up to ~570 KB seen after a package_facts: task) that would
      # otherwise be base64'd over SSH and immediately discarded by the
      # plugin that receives it.
      wire_vars = if PluginManager.needs_full_vars?(task.module_name)
                    vars_context
                  else
                    pruned = Hash(String, JSON::Any).new
                    {"ansible_connection", "ansible_host", "ansible_ssh_private_key_file"}.each do |key|
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

      config.to_json
    end

    # Matches real Ansible's `stdout_lines`/`stderr_lines` (built from
    # Python's `str.splitlines()`), not Crystal's plain `String#split("\n")`.
    # The two differ on exactly the cases that matter for real command
    # output: empty input - Python's splitlines() gives `[]`, Crystal's
    # split gives `[""]` (one empty element) - and any trailing newline,
    # which split() turns into a spurious final empty element that
    # splitlines() never produces. Found via konstruktoid-hardening's
    # "Delete unmanaged UFW rules" task: its `ufw_not_managed` command's
    # `grep -v` legitimately matches nothing (every rule this role adds is
    # tagged "ansible managed" and filtered out), producing empty stdout;
    # `ufw_not_managed.stdout_lines | length > 0` should then gate the
    # whole loop off, but the spurious `[""]` made it loop once with an
    # empty item, running `ufw delete ` with no rule spec at all - which
    # real `ufw` rejects with "ERROR: Invalid syntax".
    private def ansible_splitlines(text : String) : Array(String)
      return [] of String if text.empty?

      lines = text.split("\n")
      lines.pop if lines.last?.try(&.empty?)
      lines
    end

    # Adds stdout_lines/stderr_lines (real Ansible behavior - each module
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
    private def with_command_lines_augmented(result : JSON::Any) : JSON::Any
      result_hash = result.as_h.dup

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
      @registered_vars[host.name][register_name] = with_command_lines_augmented(result)
      @hv_generation += 1
    end

    # Run all notified handlers
  end
end
