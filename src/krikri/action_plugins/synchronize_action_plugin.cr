require "json"
require "../base_action_plugin"
require "../argspec_validator"
require "../cli_options"
require "../connection_settings"
require "../param_sentinels"
require "../plugin_helpers/synchronize_rsync"
require "../plugin_helpers/strict_bool_params"
require "../passwords"

module Krikri
  # ansible.posix.synchronize as a controller-side action plugin that
  # computes the ENTIRE task result itself (ActionResult.final - no module
  # binary is ever dispatched, local or remote).
  #
  # This mirrors Ansible's own architecture rather than working
  # around this engine's: synchronize is not a normal target-side module
  # there either. Its action plugin munges src/dest into rsync's remote
  # form and hands off to a module that ultimately shells out to the
  # `rsync` CLI - and it does so from the CONTROLLER (or the delegate_to
  # host), with rsync making its OWN connection out to the remote end.
  # Dispatched here the normal way (upload a plugin binary, run it ON the
  # target), the rsync invocation would run on the wrong machine entirely:
  # push mode's src: lives on the controller, which the target host has no
  # path to. The rsync-arg-building/execution core itself lives in
  # SynchronizeRsync (plugin_helpers/synchronize_rsync.cr), shared with
  # plugins/synchronize.cr - the standalone binary kept for `--async`/
  # manual invocation, same split as debug/pause.
  #
  # Supported and faithful: push (default; controller src -> remote dest)
  # and pull (remote src -> controller dest) over the play's own SSH
  # connection details (host/user/port, ansible_ssh_private_key_file,
  # dest_port: override); both-ends-local sync (ansible_connection=local
  # or delegate_to: localhost on a localhost task); delegate_to: localhost
  # (any local-transport delegate) on a NON-localhost task host -
  # Ansible then runs rsync on the controller with the TASK host as
  # rsync's own ssh remote (`target:/path`, no connection plugin in
  # between, verified live: a local-connection task host still gets
  # qualified by its inventory name and rsync dials it over its own
  # rsh); the full flag set (archive and its
  # toggles, checksum, compress, delete, dirs, existing_only, recursive,
  # links, copy_links, perms, times, owner, group, rsync_opts, rsync_path,
  # rsync_timeout, partial, verify_host, private_key, link_dest,
  # delay_updates, set_remote_user); role-relative src: dwim (handled
  # executor-side in resolve_role_relative_src, before this runs).
  # Idempotency comes from rsync itself - see SynchronizeRsync's
  # changed-detection comment.
  #
  # Known divergence: delegate_to: to a host that is neither localhost
  # nor the sync endpoint (Ansible runs rsync ON the delegate,
  # connecting out to the inventory host) is not modeled - here the
  # delegate-resolved host IS the endpoint, which covers the shapes real
  # roles actually write apart from that one: no delegate_to:, delegate_to:
  # localhost, and delegate_to: the task's own host.
  class SynchronizeActionPlugin < ActionPlugin
    # synchronize's `type: bool` options (ansible.posix.synchronize spec,
    # declaration order minus the engine-internal _substitute_controller).
    # AnsibleModule converts every provided bool param at module setup -
    # declaration order, first violation wins - and synchronize's module
    # body never runs on a conversion failure. Found by the kpg43 fuzz
    # round: a chaos-mutated `dirs: ylazyy` ran the whole rsync on this
    # engine while real ansible failed the task in module setup.
    include PluginHelpers::StrictBoolValidation

    protected def bool_params : Array(String)
      %w[delete archive checksum compress existing_only dirs recursive links
        copy_links perms times owner group set_remote_user use_ssh_args
        ssh_connection_multiplexing partial verify_host delay_updates]
    end

    # Ansible module success shape: exit_json(changed=, msg=, rc=, cmd=,
    # stdout_lines=) then the controller backfills failed: false last.
    # The empty msg is kept (the Ansible module passes msg=out_clean
    # explicitly, and exit_json emits the key even as "").
    SUCCESS_KEY_ORDER = ["changed", "msg", "rc", "cmd", "stdout_lines", "failed"]
    # Real failure shape: fail_json(msg=err, rc=rc, cmd=cmdstr) -
    # fail_json's kwargs dict leads (rc, cmd), then failed/msg, and the
    # controller appends changed then exception: registered as [rc, cmd,
    # failed, msg, changed, exception] (exception backfilled at register
    # via the _ansible_key_order marker - see
    # TaskExecutor#apply_failed_key_order).
    FAILURE_KEY_ORDER = ["rc", "cmd", "failed", "msg", "changed"]
    # Ansible module fail_json(msg="...") with no other kwargs: failed/msg
    # lead (fail_json's dict(failed=True, msg=msg) update), then the
    # controller's changed/exception backfill.
    PARAM_FAILURE_KEY_ORDER = ["failed", "msg", "changed"]

    # Real's action-plugin path munging crashes on a non-string YAML
    # literal src/dest (the parser marks those; see NON_STRING_PARAM_PREFIX):
    # _get_absolute_path's `':' in path` raises TypeError ("argument of
    # type '_AnsibleTaggedInt' is not iterable") on the controller-local
    # end, while _format_rsync_rsh_target's `path.startswith('rsync://')`
    # raises AttributeError ("'_AnsibleTaggedInt' object has no attribute
    # 'startswith'") on the remote-qualified end. Which end takes which
    # call follows the same dest_is_local/mode split as the munging itself
    # (live-verified vs 2.19.11 across the push/pull x src/dest x
    # local/ssh matrix): dest_is_local munges BOTH ends through
    # _get_absolute_path (always the TypeError), push remote-qualifies
    # dest and pull src. The crash precedes AnsibleModule setup, so it
    # beats a bad bool/mode param too - exactly real's ordering.
    private def munging_literal_type_failure : ActionResult?
      src_native = Krikri.non_string_scalar(@params["src"]?)
      dest_native = Krikri.non_string_scalar(@params["dest"]?)
      dest_is_local = local_connection? ||
                      ((task_host = @task_host) && !local_connection? && task_host.name == @host.name)
      # Real's munging reads the RAW mode (`get('mode', 'push') == 'pull'`,
      # case-sensitive) before the module's choices validation ever runs.
      mode = @params["mode"]? || "push"
      if src_native
        return literal_munging_crash(src_native, remote_qualified: !dest_is_local && mode == "pull")
      end
      if dest_native
        return literal_munging_crash(dest_native, remote_qualified: !dest_is_local && mode != "pull")
      end
      nil
    end

    private def literal_munging_crash(native : JSON::Any, remote_qualified : Bool) : ActionResult
      bare = if remote_qualified
               "'#{Krikri.python_scalar_type_name(native)}' object has no attribute 'startswith'"
             else
               "argument of type '#{Krikri.python_scalar_type_name(native)}' is not iterable"
             end
      ActionResult.crash_failure(bare)
    end

    # Ansible's up-front parameter check (both ends set, `is None` in the
    # action plugin), as a final failed result; nil when the params are
    # valid. A literal null (`dest:` with no value) rides the parser's
    # NON_STRING_PARAM_PREFIX marker on this plugin's params (they keep
    # the markers - see munging_literal_type_failure); real's `dest is
    # None` sees the None, so it fails here exactly like an absent one.
    # AnsibleModule setup (bool conversion, then mode's choices)
    # validation follows in execute, matching real's
    # action-plugin-before-module ordering.
    private def invalid_params_result(src_param, dest_param) : ActionResult?
      # Real's guard is `src is None or dest is None`, so a null or absent
      # src/dest fails HERE (the action plugin, before the module is ever
      # invoked), not at AnsibleModule's later missing-required check -
      # the same ordering the argspec validation below depends on
      # (issue #744). A literal null rides the parser's
      # NON_STRING_PARAM_PREFIX marker on this plugin's params (they keep
      # the markers - see munging_literal_type_failure); a null that
      # arrived through the executor's param finalization instead rides
      # the bare NONE_SENTINEL the wire uses for a natively-None value.
      if !src_param || !dest_param || src_param.empty? || dest_param.empty? ||
         marked_null_param?(src_param) || marked_null_param?(dest_param) ||
         src_param == Krikri::NONE_SENTINEL || dest_param == Krikri::NONE_SENTINEL
        return ActionResult.final(Krikri.mark_failed_key_order(ActionResult.plugin_result_json(
          false, true, "synchronize requires both src and dest parameters are set",
          key_order: PARAM_FAILURE_KEY_ORDER
        ), PARAM_FAILURE_KEY_ORDER))
      end
      nil
    end

    private def marked_null_param?(param : String?) : Bool
      ((native = Krikri.non_string_scalar(param)) && native.raw.nil?) == true
    end

    # AnsibleModule setup validation (bool type conversion in declaration
    # order, then mode's choices - types before choices in
    # parameters.py), as a final failed result; nil when valid. The
    # string-view params are what the plugin binaries'
    # validate_bool_params! also sees. Live-verified against
    # ansible-core 2.19.11 + ansible.posix 2.1.0.
    private def module_setup_validation_result : ActionResult?
      begin
        validate_bool_params_in!(@params.map { |key, value| {key, JSON::Any.new(value)} }.to_h)
      rescue e : BoolParamError
        return ActionResult.final(Krikri.mark_failed_key_order(ActionResult.plugin_result_json(
          false, true, e.message || "invalid boolean parameter",
          key_order: PARAM_FAILURE_KEY_ORDER
        ), PARAM_FAILURE_KEY_ORDER))
      end

      # mode's choices validation (parameters.py _validate_argument_values)
      # is case-sensitive and reports the RAW value; the downcase for the
      # actual transport behavior happens only after it passes. A literal
      # YAML null rides the wire as NONE_SENTINEL: real stringifies the
      # None to an empty tail ("got: " with nothing after it, live-verified
      # vs 2.19.11), not the sentinel text.
      raw_mode = @params["mode"]?
      if raw_mode && !%w[pull push].includes?(raw_mode)
        reported_mode = raw_mode == Krikri::NONE_SENTINEL ? "" : raw_mode
        return ActionResult.final(Krikri.mark_failed_key_order(ActionResult.plugin_result_json(
          false, true, "value of mode must be one of: pull, push, got: #{reported_mode}",
          key_order: PARAM_FAILURE_KEY_ORDER
        ), PARAM_FAILURE_KEY_ORDER))
      end

      # The unsupported-parameter check is the module setup's LAST check
      # (arg_spec.py appends UnsupportedError after the type/choices walk),
      # so a typo'd option name only fails once the bool/mode conversions
      # above have passed. Found by the kpg chaos round: bogus siblings of
      # real option names (_substitute_controller_bogus, checksum_bogus,
      # existin_gonly, moed) ran the whole rsync on this engine while real
      # failed the task in module setup (issue #744).
      if failure = ArgspecValidator.validate(@action_name || "ansible.posix.synchronize",
           "ansible.posix.synchronize", @params, @vars)
        return ActionResult.final(Krikri.mark_failed_key_order(ActionResult.plugin_result_json(
          false, true, failure.msg,
          key_order: PARAM_FAILURE_KEY_ORDER
        ), PARAM_FAILURE_KEY_ORDER))
      end
      nil
    end

    def execute : ActionResult
      # Real's ordering, live-verified against ansible-core 2.19.11 +
      # ansible.posix 2.1.0: the ACTION plugin's src/dest check runs
      # first (synchronize.py's `src is None or dest is None` return),
      # then the path-munging whose _get_absolute_path /
      # _format_rsync_rsh_target touches crash on a non-string literal
      # src/dest (see munging_literal_type_failure), then AnsibleModule
      # setup (bool conversion, then mode's choices).
      src_param = @params["src"]?
      dest_param = @params["dest"]?
      if invalid = invalid_params_result(src_param, dest_param)
        return invalid
      end
      if failure = munging_literal_type_failure
        return failure
      end
      # The native-type probes above are the only readers of the parser's
      # non-string-literal markers on this plugin (they reach it because
      # execute_action opts synchronize out of the strip); demote so every
      # downstream reader - bool validation, argv building, module
      # dispatch - sees the plain strings it always did.
      @params = Krikri.strip_non_string_param_markers(@params)
      if invalid = module_setup_validation_result
        return invalid
      end

      raw_mode = @params["mode"]?
      mode = (raw_mode || "push").downcase
      src = src_param.to_s
      dest = dest_param.to_s

      private_key = @params["private_key"]? || @vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
      conn_password = Passwords.connection(@vars, @host)

      # ansible.posix's own action plugin folds the connection's
      # ssh_args + ssh_common_args + ssh_extra_args into one `_ssh_args`
      # string for the module's --rsh command, but ONLY under
      # `use_ssh_args: yes` and only when that connection is the ssh
      # transport (`use_ssh_args and self._connection.transport == 'ssh'`)
      # - which is why a plain synchronize: task deliberately does NOT
      # inherit ansible_ssh_common_args (IdentitiesOnly and friends), and
      # why this is gated the same way instead of always applied.
      # Resolved through the same ConnectionSettings every other
      # transport in this engine uses; krikri has no ansible.cfg INI
      # parsing at all (env/CLI only), so real's ansible.cfg `ssh_args`
      # half of that join contributes nothing here - the CLI
      # --ssh-common-args/--ssh-extra-args do, via CliOptions.
      apply_ssh_args_param!

      # delegate_to: a local-transport host (localhost) while the task's
      # own host is a different, non-localhost host: Ansible runs
      # rsync ON THE CONTROLLER (the delegate's connection is local) and
      # qualifies the mode-dependent OTHER end from the TASK host's own
      # connection details - rsync then dials that host over its own ssh
      # (rsh), not over any connection plugin. Verified live against
      # ansible-core 2.19 + ansible.posix: a task host with
      # ansible_connection=local still gets qualified ("target:/path",
      # no user prefix unless ansible_user is set on the task host's
      # vars) and rsync fails with its own hostname-resolution error
      # when the name doesn't resolve - the munging decision reads only
      # the task host's inventory address, never its connection.
      if result = delegate_to_local_controller_path(src, dest, mode, private_key, conn_password)
        return result
      end

      # Ansible's dest_is_local edge case: delegate_to naming the task's OWN
      # host (delegate_to: "{{ inventory_hostname }}" is the common
      # spelling). Ansible's action plugin decides dest_is_local=true /
      # use_delegate=true, keeps src/dest PLAIN local paths (no
      # user@host: prefix, no --rsh, no private-key munging) and runs the
      # module ON that host, where rsync syncs the two local paths
      # directly. Mirror it by handing the params back to the executor
      # unchanged: the synchronize module binary then runs on the host
      # itself (same dispatch Ansible's _execute_module does), producing the
      # local-rsync cmd/rc/msg real registers. A remote push/pull WITHOUT
      # this delegation (rsync run from the controller, remote end
      # qualified user@host:) is unchanged below.
      if (task_host = @task_host) && !local_connection? && task_host.name == @host.name
        return ActionResult.success?(modified_params: @params)
      end

      # The delegate-resolved host (@host) is the sync endpoint. When its
      # connection is local, both ends are plain local paths (rsync runs
      # entirely on this machine); otherwise the REMOTE end gets the
      # user@host: prefix and rsync dials out over its own ssh.
      if local_connection?
        # push: src local, dest local; pull: same (both plain paths)
      elsif mode == "pull"
        src = SynchronizeRsync.format_rsh_target(connection_host, src, remote_user)
      else
        dest = SynchronizeRsync.format_rsh_target(connection_host, dest, remote_user)
      end

      dest_port = resolve_dest_port

      argv = SynchronizeRsync.build_argv(src, dest, @params, private_key, dest_port, conn_password, wrap_rsh_sshpass: SSHManager.sshpass_available?)
      finish(argv, conn_password)
    end

    private def delegate_to_local_controller_path(src : String, dest : String, mode : String, private_key : String?, conn_password : String?) : ActionResult?
      if task_host = @task_host
        if task_host.name != @host.name && local_connection? && !localhost_addr?(task_host.connection_host)
          user = SynchronizeRsync.bool(@params["set_remote_user"]?, default: true) ? @vars["ansible_user"]?.try(&.as_s?) : nil
          if mode == "pull"
            src = SynchronizeRsync.format_rsh_target(task_host.connection_host, src, user)
          else
            dest = SynchronizeRsync.format_rsh_target(task_host.connection_host, dest, user)
          end
          dest_port = resolve_dest_port(task_host)
          argv = SynchronizeRsync.build_argv(src, dest, @params, private_key, dest_port, conn_password, wrap_rsh_sshpass: SSHManager.sshpass_available?)
          return finish(argv, conn_password)
        end
      end
      nil
    end

    # Shared tail: run the rsync argv and translate its outcome into the
    # task's final result (both the delegated-to-controller path and the
    # endpoint-on-@host path end here). Same result shape the module
    # binary produces (plugins/synchronize.cr), because Ansible runs the
    # module here too and registers ITS result: exit_json/fail_json's key
    # order plus the controller's failed/changed/exception backfill.
    private def finish(argv : Array(String), conn_password : String? = nil) : ActionResult
      # Ansible module: `if '/' not in rsync: rsync = get_bin_path(rsync,
      # required=True)` - the reported cmd carries the RESOLVED path
      # (/usr/bin/rsync), not the bare name, on success and failure alike.
      argv[0] = SynchronizeRsync.resolve_bin_path(argv[0])
      result = SynchronizeRsync.run(argv, env: SSHManager.sshpass_env(conn_password))
      cmd_str = SynchronizeRsync.cmd_string(argv)

      unless result.rc == 0
        # Real: fail_json(msg=err, rc=rc, cmd=cmdstr) - msg is the raw
        # stderr even when empty (fail_json always passes msg).
        failure = ActionResult.plugin_result_json(false, true, result.error, {
          "rc"  => JSON::Any.new(result.rc.to_i64),
          "cmd" => JSON::Any.new(cmd_str),
        }, key_order: FAILURE_KEY_ORDER, include_empty_msg: true)
        return ActionResult.final(Krikri.mark_failed_key_order(failure, FAILURE_KEY_ORDER))
      end

      changed = SynchronizeRsync.changed?(result.output, !SynchronizeRsync.parse_list(@params["link_dest"]?).empty?)
      out_clean = SynchronizeRsync.clean_output(result.output)

      ActionResult.final(ActionResult.plugin_result_json(changed, false, out_clean, {
        "rc"           => JSON::Any.new(0_i64),
        "cmd"          => JSON::Any.new(cmd_str),
        "stdout_lines" => JSON::Any.new(out_clean.lines.map { |line| JSON::Any.new(line) }),
      }, key_order: SUCCESS_KEY_ORDER, include_empty_msg: true))
    end

    # Ansible's C.LOCALHOST set - the addresses that mean "this same
    # machine" to rsync's own transport.
    private def localhost_addr?(addr : String) : Bool
      ["localhost", "127.0.0.1", "::1"].includes?(addr)
    end

    private def local_connection? : Bool
      # vars first, then the name fallback: an inventory-defined
      # localhost is a plain ssh target (issue #677) - the name only
      # means "this machine" when nothing in the connection vars says
      # otherwise (the implicit localhost always carries
      # ansible_connection=local, so the vars branch answers it).
      conn = @vars["ansible_connection"]?
      return conn.try(&.as_s?) == "local" if conn
      @host.name == "localhost" || @host.name == "127.0.0.1"
    end

    private def connection_host : String
      @host.connection_host
    end

    # set_remote_user: true (default) puts user@ on the remote path -
    # from the exec host's own inventory user.
    private def remote_user : String?
      return nil unless SynchronizeRsync.bool(@params["set_remote_user"]?, default: true)
      @host.user
    end

    # dest_port: param, then the inventory's ansible_port var, then the
    # host's own parsed port. *fallback_host* is whose parsed port wins
    # when neither param nor vars carry one - the delegate-resolved @host
    # normally, but the TASK host on the delegated-to-controller path
    # (Ansible reads inv_port from the original host's task_vars).
    private def resolve_dest_port(fallback_host : Host = @host) : Int32?
      if dest_port = @params["dest_port"]?
        return dest_port.strip.to_i if dest_port.strip =~ /\A\d+\z/
      end
      return @vars["ansible_port"].as_i if @vars["ansible_port"]?.try(&.as_i?)
      fallback_host.port
    end

    # The `_ssh_args` module param real's action plugin sets for
    # `use_ssh_args: yes` - a space-joined string SynchronizeRsync
    # appends to its --rsh ssh command (its own comment quotes the
    # module line this mirrors). Gated on the same two conditions real
    # applies (the flag, and an ssh - not local - transport), so the
    # default synchronize keeps its agent/IdentitiesOnly-agnostic rsh
    # exactly like ansible.posix. No-op (and no `_ssh_args` key at all)
    # otherwise, so the params handed to a module dispatch stay
    # byte-identical to what real passes when the flag is off.
    private def apply_ssh_args_param! : Nil
      return unless SynchronizeRsync.bool(@params["use_ssh_args"]?, default: false)
      return if local_connection?
      conn = ConnectionSettings.resolve(@host, @vars)
      args = CliOptions.extra_ssh_args + conn.ssh_extra_options
      return if args.empty?
      @params["_ssh_args"] = args.join(' ')
    end
  end
end
