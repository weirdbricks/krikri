require "json"
require "../base_action_plugin"
require "../plugin_helpers/synchronize_rsync"

module Krikri
  # ansible.posix.synchronize as a controller-side action plugin that
  # computes the ENTIRE task result itself (ActionResult.final - no module
  # binary is ever dispatched, local or remote).
  #
  # This mirrors real Ansible's own architecture rather than working
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
  # (any local-transport delegate) on a NON-localhost task host - real
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
  # nor the sync endpoint (real Ansible runs rsync ON the delegate,
  # connecting out to the inventory host) is not modeled - here the
  # delegate-resolved host IS the endpoint, which covers the shapes real
  # roles actually write apart from that one: no delegate_to:, delegate_to:
  # localhost, and delegate_to: the task's own host.
  class SynchronizeActionPlugin < ActionPlugin
    def execute : ActionResult
      src_param = @params["src"]?
      dest_param = @params["dest"]?

      if !src_param || !dest_param || src_param.empty? || dest_param.empty?
        return ActionResult.final(ActionResult.plugin_result_json(
          false, true, "synchronize requires both src and dest parameters are set"
        ))
      end

      mode = (@params["mode"]? || "push").downcase
      unless ["push", "pull"].includes?(mode)
        return ActionResult.final(ActionResult.plugin_result_json(
          false, true, "mode must be 'push' or 'pull', got '#{mode}'"
        ))
      end

      src = src_param.to_s
      dest = dest_param.to_s

      private_key = @params["private_key"]? || @vars["ansible_ssh_private_key_file"]?.try(&.as_s?)

      # delegate_to: a local-transport host (localhost) while the task's
      # own host is a different, non-localhost host: real Ansible runs
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
      if result = delegate_to_local_controller_path(src, dest, mode, private_key)
        return result
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

      argv = SynchronizeRsync.build_argv(src, dest, @params, private_key, dest_port)
      finish(argv)
    end

    private def delegate_to_local_controller_path(src : String, dest : String, mode : String, private_key : String?) : ActionResult?
      if task_host = @task_host
        if task_host.name != @host.name && local_connection? && !localhost_addr?(task_host.connection_host)
          user = SynchronizeRsync.bool(@params["set_remote_user"]?, default: true) ? @vars["ansible_user"]?.try(&.as_s?) : nil
          if mode == "pull"
            src = SynchronizeRsync.format_rsh_target(task_host.connection_host, src, user)
          else
            dest = SynchronizeRsync.format_rsh_target(task_host.connection_host, dest, user)
          end
          dest_port = resolve_dest_port(task_host)
          argv = SynchronizeRsync.build_argv(src, dest, @params, private_key, dest_port)
          return finish(argv)
        end
      end
      nil
    end

    # Shared tail: run the rsync argv and translate its outcome into the
    # task's final result (both the delegated-to-controller path and the
    # endpoint-on-@host path end here).
    private def finish(argv : Array(String)) : ActionResult
      result = SynchronizeRsync.run(argv)
      cmd_str = result.command.join(" ")

      unless result.rc == 0
        msg = result.error.empty? ? result.output : result.error
        return ActionResult.final(ActionResult.plugin_result_json(false, true, msg, {
          "rc"  => JSON::Any.new(result.rc.to_i64),
          "cmd" => JSON::Any.new(cmd_str),
        }))
      end

      changed = SynchronizeRsync.changed?(result.output, !SynchronizeRsync.parse_list(@params["link_dest"]?).empty?)
      out_clean = SynchronizeRsync.clean_output(result.output)

      ActionResult.final(ActionResult.plugin_result_json(changed, false, out_clean, {
        "rc"           => JSON::Any.new(0_i64),
        "cmd"          => JSON::Any.new(cmd_str),
        "stdout_lines" => JSON::Any.new(out_clean.lines.map { |line| JSON::Any.new(line) }),
      }))
    end

    # Real Ansible's C.LOCALHOST set - the addresses that mean "this same
    # machine" to rsync's own transport.
    private def localhost_addr?(addr : String) : Bool
      ["localhost", "127.0.0.1", "::1"].includes?(addr)
    end

    private def local_connection? : Bool
      return true if @host.name == "localhost" || @host.name == "127.0.0.1"
      conn = @vars["ansible_connection"]?
      conn.try(&.as_s?) == "local"
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
    # (real Ansible reads inv_port from the original host's task_vars).
    private def resolve_dest_port(fallback_host : Host = @host) : Int32?
      if dest_port = @params["dest_port"]?
        return dest_port.strip.to_i if dest_port.strip =~ /\A\d+\z/
      end
      return @vars["ansible_port"].as_i if @vars["ansible_port"]?.try(&.as_i?)
      fallback_host.port
    end
  end
end
