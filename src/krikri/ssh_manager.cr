require "process"
require "file_utils"
require "json"

# SSH Manager - CLI-based implementation
# Uses native SSH command with ControlMaster for connection pooling
require "./cli_options"
require "./shell"
require "./timing_profile"

module Krikri
  class SSHManager
    # Default per-command execution timeout for #exec/#exec_script/
    # #daemon_send. Real Ansible has NO default command-duration limit
    # at all - a foreground task runs until it completes, however long
    # that takes (only `async:` tasks get an explicit max duration);
    # what actually detects a genuinely dead/unreachable host is the SSH
    # connection's own keepalive (ServerAliveInterval=60 x
    # ServerAliveCountMax=3 below, ~180s to a hard disconnect), which
    # this timeout duplicates and undercuts. Previously 300s (5 minutes)
    # - too short for entirely ordinary, legitimately slow real-world
    # tasks: found live re-benchmarking buluma.netdata (round 163
    # regression check) - its own installer genuinely compiles from
    # source and took a confirmed 1536s (~25.6 minutes) on the real
    # ansible-playbook side; crystal's identical task was killed at
    # exactly 300s ("SSH command timed out... did not exit even after
    # being killed") despite the remote command still actively running
    # and eventually would have succeeded. The same 300s cap likely also
    # explains 2 earlier "flaky"-looking incidents this session
    # (robertdebock.luks, geerlingguy.java - both ordinary `dnf install`
    # calls that occasionally took a bit over 300s on a slow mirror/cold
    # host, not a genuine hang) that were chased down as one-off infra
    # flakiness via isolated re-tests rather than recognized as this
    # same root cause at the time. Raised to a generous but still-bounded
    # 1 hour - long enough for realistic compile-from-source/large-
    # package-install tasks, while the SSH keepalive above still catches
    # a truly dead connection in ~3 minutes regardless of this value.
    DEFAULT_EXEC_TIMEOUT_SECONDS = 3600

    # Control socket directory - STABLE across processes (no pid suffix),
    # with per-(user, host, port) socket names below it, mirroring real
    # Ansible's own ssh.py connection plugin (a fixed ~/.ansible/cp dir,
    # one hashed socket per target). Cross-PROCESS master reuse is real
    # Ansible behavior: a second `ansible-playbook` invocation minutes
    # after the first rides the first run's still-alive ControlPersist
    # master instead of dialing a fresh incoming TCP connection - which
    # is the ONLY thing that kept f500.ufw's warm rerun reachable (the
    # role leaves `ufw default deny incoming` + `ufw --force enable`
    # with no allow rules; any NEW incoming connection - krikri's warm
    # run included - times out, and real Ansible's own warm rerun fails
    # identically once its master socket is moved away, verified live on
    # fresh Atlantic.net hosts). The per-process (pid-suffixed) layout
    # this replaced (0.9.770) traded that reuse away to fix a concurrent-
    # process mux race; the pid-scoped dir meant a new process could
    # never find a previous run's master even when one was alive, so
    # every krikri invocation dialed fresh. Socket names here are already
    # per-target (get_control_path), so concurrent processes on DIFFERENT
    # hosts never share a socket; concurrent clients on the SAME host's
    # mux socket are exactly what real Ansible does and what the ssh mux
    # protocol itself is designed for.
    @@control_path_dir = "/tmp/.krikri-playbook-ssh"

    # Read-only accessor for diagnostics/specs - the stable control-socket
    # directory itself carries no secrets, and the spec suite pins its
    # pid-independence (the exact property f500.ufw's warm-rerun lockout
    # hinged on).
    def self.control_path_dir : String
      @@control_path_dir
    end

    # Connection pool statistics
    @@stats = {
      "connections_created" => 0,
      "connections_reused"  => 0,
      "commands_executed"   => 0,
      "files_uploaded"      => 0,
      "files_downloaded"    => 0,
    }

    # Initialize - ensure control directory exists.
    # Called from exec/exec_script/upload/download/rsync_upload/
    # rsync_upload_batch, i.e. once per SSH operation, for a directory
    # that only ever needs creating once - so the Dir.exists? stat is
    # guarded by a flag rather than re-run every time.
    @@control_dir_ready = false

    def self.init : Nil
      return if @@control_dir_ready
      Dir.mkdir_p(@@control_path_dir) unless Dir.exists?(@@control_path_dir)
      # Control sockets live here; a predictable /tmp path must never be
      # group/world-readable (0700 also blocks another local user
      # pre-creating the dir before we do and hijacking the sockets).
      File.chmod(@@control_path_dir, 0o700)
      @@control_dir_ready = true
    end

    # Get connection pool statistics
    def self.stats : Hash(String, Int32)
      @@stats
    end

    # Runs *block* (given the just-spawned *process*) on a separate fiber
    # and bounds it to *timeout_seconds* wall-clock time - both `exec`
    # and `exec_script` accepted a `timeout:` parameter that was never
    # actually enforced anywhere, leaving every blocking Process call
    # (`#wait`, and for exec_script, the write of a potentially large
    # script into the process's own stdin pipe) able to hang forever
    # with no escape hatch at all. `-o ServerAliveInterval=`/
    # `ServerAliveCountMax=` only bound an *established* SSH session
    # going idle - they do nothing for a local pipe write blocking
    # because nothing is reading the other end (the remote host went
    # unreachable mid-handshake, before ssh itself even started
    # forwarding stdin), which is a local blocking syscall the SSH
    # protocol's own keepalive machinery never sees. Found running
    # konstruktoid-hardening's newly-batched (0.9.155) 411-item "Find
    # possible suid binaries" step: the whole krikri-playbook process
    # sat silent, producing no further output and no error, until an
    # *external* `timeout` wrapper eventually killed it - a real host/
    # network hang, not a task bug, and previously nothing inside
    # krikri-playbook itself could ever recover from it.
    #
    # On timeout, SIGKILLs the process and gives it a further 5s to
    # actually exit and report a status before giving up entirely (a
    # hard bound of its own, in case even the kill signal doesn't
    # unblock the fiber - e.g. if it's wedged in kernel-level uninter-
    # ruptible I/O, vanishingly rare but not impossible).
    #
    # Fiber lifecycle on the timeout path (audited, not assumed): the
    # SIGKILL guarantees the child dies, which unblocks the spawned
    # fiber's `#wait` (or errors its stdin pipe write with EPIPE), so
    # the fiber completes and its result lands in the capacity-1
    # channel - either received within the 5s grace (the killed
    # process's real exit status is then returned, e.g. 137) or, if
    # even that doesn't arrive in time, discarded when this method
    # returns and the channel is garbage. Either way the fiber
    # terminates on its own; nothing leaks permanently.
    #
    # Public (not private) so the timeout semantics can be spec'd
    # directly against a real local process - see
    # spec/unit/ssh_manager_timeout_spec.cr.
    def self.run_with_timeout(
      process : Process,
      timeout_seconds : Int32,
      &block : Process -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      channel = Channel(NamedTuple(exit_code: Int32, stdout: String, stderr: String)).new(1)

      spawn do
        result = begin
          block.call(process)
        rescue ex
          {exit_code: 255, stdout: "", stderr: "SSH execution failed: #{ex.message}"}
        end
        channel.send(result)
      end

      select
      when result = channel.receive
        result
      when timeout(timeout_seconds.seconds)
        begin
          process.terminate(graceful: false)
        rescue
        end
        select
        when result = channel.receive
          result
        when timeout(5.seconds)
          {exit_code: 255, stdout: "", stderr: "SSH command timed out after #{timeout_seconds}s (host likely unreachable) and did not exit even after being killed"}
        end
      end
    end

    # Process::Status#exit_code raises RuntimeError for a signal-killed
    # process - the run_with_timeout SIGKILL path is exactly that case,
    # so a killed child used to blow up the result block instead of
    # reporting a status. Map a signal death to the conventional
    # 128+signal value; anything else passes through unchanged.
    private def self.signal_safe_exit_code(status : Process::Status) : Int32
      status.normal_exit? ? status.exit_code : 128 + status.exit_signal.to_i
    end

    # stderr shapes only ssh(1) itself (or this class's own rescue/
    # timeout paths) ever produce - the transport-level failure evidence
    # that separates "no command ever ran on the remote" from "the
    # remote plugin crashed after a successful connection". Deliberately
    # narrow, conservative in BOTH directions:
    #   - A remote module crash's stderr comes from the remote bash/
    #     plugin process (a loader error like "error while loading
    #     shared libraries", a traceback, a plain "Permission denied"
    #     from touching a root-owned file) - none of those match these
    #     shapes, so it keeps its generic failed-task booking.
    #     "Permission denied" specifically only matches with ssh's own
    #     " (publickey..." auth-method list attached, which a remote
    #     command's stderr never carries.
    #   - Conversely a remote command COULD print transport-adjacent
    #     text of its own (a curl's "Connection timed out"), so bare
    #     phrases like that are NOT matched here - the connect-failure
    #     shape is only recognized with ssh's own "ssh: connect to host"
    #     prefix attached.
    # ssh(1) exits 255 for every one of these, hence the exit-code gate.
    private CONNECTION_FAILURE_PATTERNS = [
      "ssh: connect to host",         # connect refused/timed out/no route/network unreachable
      "Could not resolve hostname",   # ssh: Could not resolve hostname X ...
      "Permission denied (publickey", # auth never succeeded (ssh appends the method list)
      "kex_exchange_identification",  # banner exchange failed/reset
      "ssh_exchange_identification",
      "Host key verification failed",
      "SSH command timed out",       # run_with_timeout's own hung-connection synthesis
      "SSH execution failed",        # exec's rescue path
      "SSH script execution failed", # exec_script's rescue path
    ]

    # True when *exit_code*/*stderr* look like the SSH transport itself
    # failing - ssh never reached or never authenticated to the host -
    # as opposed to a remote plugin crashing after a successful
    # connection. Public so PluginManager's remote-result interpretation
    # and the spec suite share one pattern list (see
    # CONNECTION_FAILURE_PATTERNS for what deliberately does NOT match).
    def self.connection_level_failure?(exit_code : Int32, stderr : String) : Bool
      return false if exit_code == 0
      CONNECTION_FAILURE_PATTERNS.any? { |pattern| stderr.includes?(pattern) }
    end

    # Exception counterpart of #connection_level_failure? - an scp/rsync/
    # ssh failure surfaces as a raised "Failed to upload/download ..."
    # whose detail embeds ssh's own stderr, so the same pattern list
    # decides whether the exception means "the transport never got
    # there" (UNREACHABLE in real Ansible) or something else that must
    # keep propagating (a missing local file, a staging-dir safety
    # refusal, an engine bug). Message-only, no exit code to gate on.
    def self.connection_level_exception?(ex : Exception) : Bool
      message = ex.message.to_s
      CONNECTION_FAILURE_PATTERNS.any? { |pattern| message.includes?(pattern) } ||
        message.includes?("scp: Connection closed")
    end

    # Reset statistics
    def self.reset_stats : Nil
      @@stats.each_key do |key|
        @@stats[key] = 0
      end
    end

    # Execute command on remote host
    # *port* nil means "let ssh resolve it" (no -p flag; ~/.ssh/config and
    # /etc/ssh/ssh_config apply) - only an explicit port overrides.
    def self.exec(
      host : String,
      user : String,
      command : String,
      port : Int32? = nil,
      timeout : Int32 = DEFAULT_EXEC_TIMEOUT_SECONDS,
      identity_file : String? = nil,
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      init
      @@stats["commands_executed"] += 1

      # Build SSH command with ControlMaster for connection pooling
      control_path = get_control_path(host, user, port)

      # Important: We pass the command through bash -c to ensure proper shell
      # interpretation on the remote side. This prevents the local shell from
      # interpreting operators like ||, &&, |, >, etc.
      # We use /bin/bash instead of /bin/sh for better compatibility
      wrapped_command = "/bin/bash -c #{shell_quote(command)}"

      ssh_cmd = [
        "ssh",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600", # Keep connection alive for 10 minutes
        "-o", "ConnectTimeout=#{CliOptions.timeout}",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=#{strict_host_key_checking}",
      ] + identity_args(identity_file) + (port ? ["-p", port.to_s] : [] of String) + [
        "#{user}@#{host}",
        wrapped_command,
      ]

      stdout = IO::Memory.new
      stderr = IO::Memory.new

      TimingProfile.measure("transport.ssh_exec", "transport") do
        begin
          process = TimingProfile.measure("transport.ssh_spawn", "transport.spawn") do
            Process.new(
              ssh_cmd[0],
              ssh_cmd[1..],
              output: stdout,
              error: stderr
            )
          end

          run_with_timeout(process, timeout) do |proc|
            status = proc.wait
            {
              exit_code: signal_safe_exit_code(status),
              stdout:    stdout.to_s,
              stderr:    stderr.to_s,
            }
          end
        rescue ex
          {
            exit_code: 255,
            stdout:    "",
            stderr:    "SSH execution failed: #{ex.message}",
          }
        end
      end
    end

    # Runs *script* on the remote host via `ssh ... bash -s`, piped over
    # that single invocation's own stdin - used by TaskExecutor's batch
    # path (batching, on by default; --no-batching disables it) to run
    # several plugin invocations
    # in one SSH round trip. Deliberately separate from `exec`: `exec`
    # wraps a command through `bash -c <string>`, which has no stdin of
    # its own to carry a whole script through; this uses `bash -s`
    # (reads its script from stdin) specifically so the caller can hand
    # over a multi-step script without needing to escape it into a
    # single command-line string.
    def self.exec_script(
      host : String,
      user : String,
      script : String,
      port : Int32? = nil,
      timeout : Int32 = DEFAULT_EXEC_TIMEOUT_SECONDS,
      identity_file : String? = nil,
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      init
      @@stats["commands_executed"] += 1

      control_path = get_control_path(host, user, port)

      ssh_cmd = [
        "ssh",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "ConnectTimeout=#{CliOptions.timeout}",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=#{strict_host_key_checking}",
      ] + identity_args(identity_file) + (port ? ["-p", port.to_s] : [] of String) + [
        "#{user}@#{host}",
        "bash", "-s",
      ]

      stdout = IO::Memory.new
      stderr = IO::Memory.new

      TimingProfile.measure("transport.ssh_script", "transport") do
        begin
          process = TimingProfile.measure("transport.ssh_spawn", "transport.spawn") do
            Process.new(
              ssh_cmd[0],
              ssh_cmd[1..],
              input: Process::Redirect::Pipe,
              output: stdout,
              error: stderr
            )
          end

          run_with_timeout(process, timeout) do |proc|
            proc.input.print(script)
            proc.input.close

            status = proc.wait
            {
              exit_code: signal_safe_exit_code(status),
              stdout:    stdout.to_s,
              stderr:    stderr.to_s,
            }
          end
        rescue ex
          {
            exit_code: 255,
            stdout:    "",
            stderr:    "SSH script execution failed: #{ex.message}",
          }
        end
      end
    end

    # Perf items 1-3 (formerly
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15, a doc since
    # deleted) - the persistent
    # remote executor's controller half. `exec`/`exec_script` above pay
    # a fresh local `ssh` fork + remote process spawn on EVERY call,
    # multiplexed over the same ControlMaster TCP session but never
    # reusing the actual spawned processes. This instead keeps ONE
    # `ssh ... -- <fat-plugin> --daemon` `Process` alive per (host,
    # user, port) and speaks the length-prefixed protocol
    # `plugin_daemon.cr` implements on the remote end directly over that
    # process's own stdin/stdout pipes - every subsequent call is a
    # plain write+read on an already-open pipe, no new process on
    # either side.
    #
    # Deliberately opt-in (only reached when `PluginManager.
    # daemon_enabled?` is true) and only used for the SOLO, non-become
    # remote-dispatch path - see `PluginManager.daemon_eligible?`'s own
    # comment for exactly what's excluded and why. Keyed identically to
    # `@@control_path_cache` above, same one-fiber-per-host safety
    # argument `executor.cr`'s own `run_task_for_hosts_in_parallel`
    # comment already documents - a given host's daemon connection is
    # never touched by two fibers at once, so no correlation ID or lock
    # is needed on top of this Hash.
    # Perf item 1: keyed on the become_user
    # too, not just (host, user, port). A daemon is one resident process
    # running as one fixed user, so `become: true` tasks cannot share
    # the unprivileged host connection's daemon - but they can have
    # their own, spawned as `sudo -n -u <become_user> -- <binary>
    # --daemon`. A play mixing privileged and unprivileged tasks holds
    # two resident daemons per host, which is fine. `nil` in the last
    # slot is the no-become daemon.
    alias DaemonKey = {String, String, Int32?, String?}

    @@daemon_processes = Hash(DaemonKey, Process).new

    # Consecutive daemon failures per key. A daemon that cannot be
    # started at all - `sudo -n` refused because this host wants a
    # password, `requiretty` in sudoers, a NOPASSWD rule that covers
    # the one-shot command but not this one - would otherwise cost a
    # wasted ssh spawn on EVERY task for the rest of the run before
    # falling back, turning item 1 into a net slowdown on exactly the
    # hosts where it doesn't apply. After MAX_DAEMON_FAILURES in a row
    # the key stops being tried and every task for it takes the
    # per-task path directly.
    #
    # Consecutive, not cumulative, and reset by any success: a daemon
    # dying once because `ansible.builtin.reboot` killed the SSH
    # session mid-play must still be lazily respawned afterwards (see
    # #daemon_send's own comment - that is the whole reconnect story),
    # and a threshold of 3 leaves ample room for that while still
    # bounding a hard failure to three wasted attempts.
    @@daemon_failures = Hash(DaemonKey, Int32).new(0)
    MAX_DAEMON_FAILURES = 3

    # Whether a daemon for this key is worth attempting at all. Public
    # so PluginManager can skip the attempt before building a request,
    # rather than learning about it from a raised exception.
    def self.daemon_unavailable?(host : String, user : String, port : Int32?, become_user : String?) : Bool
      @@daemon_failures[{host, user, port, become_user}] >= MAX_DAEMON_FAILURES
    end

    # Sends one request and returns the plugin's own JSON result,
    # unwrapped - unlike `exec`/`exec_script`, there is no exit-code-vs-
    # stdout arbitration to do here (that was a one-shot-process
    # concept; `interpret_remote_result` doesn't apply to a persistent
    # pipe), the daemon's response IS the plugin's real output.
    #
    # On ANY failure (spawn error, broken pipe, timeout, malformed
    # response) the connection is torn down and NOT retried here - the
    # exception propagates to `PluginManager`, whose job is to catch it
    # and fall back to `execute_remote_plugin`'s existing, already-
    # proven per-task path for that one call. This is deliberately the
    # WHOLE reconnect story: a stale daemon (e.g. after `ansible.
    # builtin.reboot` killed the SSH session mid-play) fails exactly
    # once, falls back safely for that one task, and a fresh daemon gets
    # lazily spawned the next time this host needs one - no explicit
    # reboot-awareness needed anywhere in this method.
    def self.daemon_send(
      host : String,
      user : String,
      port : Int32?,
      remote_binary_path : String,
      module_name : String,
      config : JSON::Any,
      identity_file : String? = nil,
      timeout : Int32 = DEFAULT_EXEC_TIMEOUT_SECONDS,
      become_user : String? = nil,
    ) : JSON::Any
      init
      key = {host, user, port, become_user}
      process = @@daemon_processes[key]? ||
                spawn_daemon(host, user, port, remote_binary_path, identity_file, become_user)

      request = {"module" => module_name, "config" => config}.to_json

      response = TimingProfile.measure("transport.daemon_send", "transport") do
        run_io_with_timeout(timeout) do
          write_daemon_frame(process.input, request)
          read_daemon_frame(process.output)
        end
      end

      @@daemon_failures.delete(key)
      JSON.parse(response)
    rescue ex
      @@daemon_failures[{host, user, port, become_user}] += 1
      kill_daemon(host, user, port, become_user)
      raise ex
    end

    # Perf item 3: send a whole batch of
    # steps as ONE daemon request. Same connection, same framing and the
    # same rescue-and-let-the-caller-fall-back contract as #daemon_send
    # above; only the payload shape differs.
    #
    # Returns the plugin results keyed by the step's index in *steps*. An
    # index that is ABSENT never ran - the daemon stopped at an earlier
    # failing step, exactly as `BatchScript.parse` reports a script that
    # halted. Callers must honour that the same way they already do for
    # the script transport.
    #
    # Every step here must agree on become_user, because that is what
    # selects which resident daemon (and therefore which user) serves
    # them - see TaskExecutor#run_batch_steps, which does the
    # partitioning.
    def self.daemon_send_batch(
      host : String,
      user : String,
      port : Int32?,
      remote_binary_path : String,
      steps : Array(NamedTuple(module_name: String, config: JSON::Any, ignore_errors: Bool)),
      identity_file : String? = nil,
      timeout : Int32 = DEFAULT_EXEC_TIMEOUT_SECONDS,
      become_user : String? = nil,
    ) : Hash(Int32, JSON::Any)
      init
      key = {host, user, port, become_user}
      process = @@daemon_processes[key]? ||
                spawn_daemon(host, user, port, remote_binary_path, identity_file, become_user)

      payload = steps.map do |step|
        {
          "module"        => JSON::Any.new(step[:module_name]),
          "config"        => step[:config],
          "ignore_errors" => JSON::Any.new(step[:ignore_errors]),
        }
      end
      request = {"batch" => payload}.to_json

      response = TimingProfile.measure("transport.daemon_batch", "transport") do
        run_io_with_timeout(timeout) do
          write_daemon_frame(process.input, request)
          read_daemon_frame(process.output)
        end
      end

      @@daemon_failures.delete(key)

      results = Hash(Int32, JSON::Any).new
      JSON.parse(response)["results"].as_h.each do |index, value|
        results[index.to_i] = value
      end
      results
    rescue ex
      @@daemon_failures[{host, user, port, become_user}] += 1
      kill_daemon(host, user, port, become_user)
      raise ex
    end

    # *become_user* non-nil spawns the daemon under `sudo -n -u <user>
    # --`, the exact wrapper `PluginManager.remote_plugin_target`
    # already builds for the one-shot path - deliberately the same
    # escalation, so a host where the one-shot become path works has a
    # daemon that works too, and one where it doesn't fails the same
    # way (loudly, at spawn, then falls back).
    private def self.spawn_daemon(host : String, user : String, port : Int32?, remote_binary_path : String, identity_file : String?, become_user : String? = nil) : Process
      control_path = get_control_path(host, user, port)

      ssh_cmd = [
        "ssh",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "ConnectTimeout=#{CliOptions.timeout}",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=#{strict_host_key_checking}",
      ] + identity_args(identity_file) + (port ? ["-p", port.to_s] : [] of String) + [
        "#{user}@#{host}",
        daemon_remote_command(remote_binary_path, become_user),
      ]

      process = TimingProfile.measure("transport.daemon_spawn", "transport.spawn") do
        Process.new(
          ssh_cmd[0],
          ssh_cmd[1..],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Close
        )
      end
      @@daemon_processes[{host, user, port, become_user}] = process
      process
    end

    # become_user is interpolated into a shell command line here, same
    # as the one-shot path's own target string - it is expected to have
    # already passed `PluginManager.valid_become_user?` at the call
    # site, which is where that allow-list is enforced for both paths.
    private def self.daemon_remote_command(remote_binary_path : String, become_user : String?) : String
      return "#{remote_binary_path} --daemon" unless become_user
      "sudo -n -u #{become_user} -- #{remote_binary_path} --daemon"
    end

    private def self.write_daemon_frame(io : IO, payload : String) : Nil
      bytes = payload.to_slice
      io.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(bytes)
      io.flush
    end

    private def self.read_daemon_frame(io : IO) : String
      length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      bytes = Bytes.new(length)
      io.read_fully(bytes)
      String.new(bytes)
    end

    # Same "bound a blocking local pipe op to a wall-clock timeout on a
    # separate fiber" shape as `run_with_timeout` above (see that
    # method's own comment for why `ServerAliveInterval`/
    # `ServerAliveCountMax` can't cover this - a local pipe read/write
    # with nothing on the other end is invisible to SSH's own keepalive
    # machinery), generalized over the return type since a daemon
    # request returns a plain `String`, not the `exec`/`exec_script`-
    # specific `NamedTuple`. No SIGKILL escalation here - unlike a
    # one-shot process, a daemon `Process` is meant to outlive this one
    # call, so a timeout just raises and lets the `rescue` in
    # `#daemon_send` tear the connection down through the normal
    # `#kill_daemon` path instead of a bespoke kill sequence here.
    private def self.run_io_with_timeout(timeout_seconds : Int32, &block : -> String) : String
      result_channel = Channel(String).new(1)
      error_channel = Channel(Exception).new(1)

      spawn do
        begin
          result_channel.send(block.call)
        rescue ex
          error_channel.send(ex)
        end
      end

      select
      when result = result_channel.receive
        result
      when ex = error_channel.receive
        raise ex
      when timeout(timeout_seconds.seconds)
        raise "daemon request timed out after #{timeout_seconds}s (host likely unreachable)"
      end
    end

    # Best-effort, no grace period - used from #daemon_send's own
    # rescue, where something has already gone wrong and the priority is
    # dropping the stale connection so the NEXT call spawns a fresh one,
    # not waiting around for a clean exit that may never come.
    private def self.kill_daemon(host : String, user : String, port : Int32?, become_user : String? = nil) : Nil
      process = @@daemon_processes.delete({host, user, port, become_user})
      return unless process

      begin
        process.input.close
      rescue
      end
      begin
        process.terminate(graceful: false) unless process.terminated?
      rescue
      end
    end

    # meta: reset_connection - drops this host's persistent connection
    # state so the next task opens fresh connections. Two layers exist
    # here: the resident plugin daemons (one ssh process per
    # host/user/port/become_user) and ssh's own ControlMaster socket
    # underneath them. Both are dropped for every key matching the host;
    # the `ssh -O exit` is best-effort (no master socket = no-op).
    def self.reset_connection(host_name : String) : Nil
      matching = @@daemon_processes.keys.select { |(h, _, _, _)| h == host_name }
      matching.each do |key|
        kill_daemon(*key)
        host, user, port, _ = key
        control_path = get_control_path(host, user, port)
        Process.run("ssh", ["-O", "exit", "-o", "ControlPath=#{control_path}", "#{user}@#{host}"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
    end

    # Graceful shutdown for every still-open daemon connection, called
    # once at the end of a run. Closes every daemon's stdin first (each
    # one sees EOF and exits cleanly via `plugin_daemon.cr`'s own
    # `rescue IO::EOFError` - no explicit "goodbye" message needed),
    # THEN waits once for the whole batch rather than once per
    # connection, force-killing stragglers only after that single grace
    # period - materially faster than `#kill_daemon`'s per-connection
    # path would be for a multi-host run.
    def self.close_all_daemons : Nil
      processes = @@daemon_processes.values
      @@daemon_processes.clear
      return if processes.empty?

      processes.each do |process|
        begin
          process.input.close
        rescue
        end
      end

      # Poll for the batch to exit rather than sleeping a flat second.
      # This used to be `sleep 1.second` unconditionally, which was a
      # rounding error while `become:` tasks were daemon-ineligible (a
      # typical all-`become:` role held no daemons at all, so this
      # returned early at the `processes.empty?` guard above and cost
      # nothing). Perf item 1 changed that:
      # now essentially every real run holds at least one daemon, and a
      # flat second on the way out was eating a third of item 1's own
      # measured warm-run saving on devsec.hardening.os_hardening -
      # visible as an exactly-1.001s "unaccounted" row in the item-0
      # timing profile, which is what made it obvious.
      #
      # The backoff starts at 1ms rather than a fixed 20ms interval
      # because a daemon sees EOF and exits in about a millisecond: at a
      # flat 20ms this loop reliably burned two whole ticks (a 0.041s
      # "unaccounted" row - measured, on every single run), which is
      # material on a short play. Item 2 made that worse by giving even
      # a facts-only play a daemon to shut down. Doubling to a 20ms
      # ceiling keeps a long-tail straggler cheap to wait on, and the 1s
      # hard deadline is unchanged.
      deadline = Time.monotonic + 1.second
      interval = 1.millisecond
      while Time.monotonic < deadline
        break if processes.all?(&.terminated?)
        sleep interval
        interval = {interval * 2, 20.milliseconds}.min
      end

      processes.each do |process|
        begin
          process.terminate(graceful: false) unless process.terminated?
        rescue
        end
      end
    end

    # Upload file to remote host via SCP
    def self.upload(
      host : String,
      user : String,
      local_path : String,
      remote_path : String,
      port : Int32? = nil,
      mode : Int32? = 0o644,
      identity_file : String? = nil,
      recursive : Bool = false,
    )
      init
      @@stats["files_uploaded"] += 1

      unless recursive ? Dir.exists?(local_path) : File.exists?(local_path)
        raise "Local file not found: #{local_path}"
      end

      control_path = get_control_path(host, user, port)

      # Use scp with ControlMaster to reuse SSH connection
      scp_cmd = [
        "scp",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "ConnectTimeout=#{CliOptions.timeout}",
        "-o", "StrictHostKeyChecking=#{strict_host_key_checking}",
      ] + (recursive ? ["-r"] : [] of String) + identity_args(identity_file) +
                (port ? ["-P", port.to_s] : [] of String) +
                CliOptions.extra_scp_args + [
        local_path,
        "#{user}@#{host}:#{remote_path}",
      ]

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = TimingProfile.measure("transport.scp_upload", "transport") do
        Process.run(
          scp_cmd[0],
          scp_cmd[1..],
          output: out_io,
          error: err_io
        )
      end

      unless result.exit_code? == 0
        detail = (err_io.to_s + out_io.to_s).strip
        detail = detail.empty? ? "no output" : detail
        raise "Failed to upload #{local_path} to #{host}:#{remote_path}: #{detail}"
      end

      # Set permissions if different from default. Pass `mode: nil` to
      # suppress this entirely when the caller is uploading a batch of
      # files and can fold one chmod into a round trip it already makes -
      # otherwise this costs an extra round trip *per file*.
      if mode && mode != 0o644
        exec(host, user, "chmod #{mode.to_s(8)} #{remote_path}", port, identity_file: identity_file)
      end
    end

    # Download file from remote host via SCP
    def self.download(
      host : String,
      user : String,
      remote_path : String,
      local_path : String,
      port : Int32? = nil,
      identity_file : String? = nil,
    )
      init
      @@stats["files_downloaded"] += 1

      control_path = get_control_path(host, user, port)

      # Use scp with ControlMaster to reuse SSH connection
      scp_cmd = [
        "scp",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "StrictHostKeyChecking=#{strict_host_key_checking}",
      ] + identity_args(identity_file) + (port ? ["-P", port.to_s] : [] of String) +
                CliOptions.extra_scp_args + [
        "#{user}@#{host}:#{remote_path}",
        local_path,
      ]

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = TimingProfile.measure("transport.scp_download", "transport") do
        Process.run(
          scp_cmd[0],
          scp_cmd[1..],
          output: out_io,
          error: err_io
        )
      end

      unless result.exit_code? == 0
        detail = (err_io.to_s + out_io.to_s).strip
        detail = detail.empty? ? "no output" : detail
        raise "Failed to download #{host}:#{remote_path} to #{local_path}: #{detail}"
      end
    end

    # Whether the `rsync` binary is available locally. Resolved once per
    # process (a `which rsync` spawn per call was pure overhead - rsync
    # availability doesn't change mid-run).
    @@rsync_available : Bool? = nil

    private def self.rsync_available? : Bool
      cached = @@rsync_available
      return cached unless cached.nil?

      result = Process.run("which", ["rsync"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      @@rsync_available = result.exit_code? == 0
    end

    # Upload file using rsync (more efficient for incremental updates)
    # Returns true if successful, false if rsync not available or failed
    def self.rsync_upload(
      host : String,
      user : String,
      local_path : String,
      remote_path : String,
      port : Int32? = nil,
      mode : Int32 = 0o644,
      identity_file : String? = nil,
    ) : Bool
      init

      return false unless rsync_available?

      control_path = get_control_path(host, user, port)

      # Use rsync with SSH control master
      rsync_cmd = [
        "rsync",
        "-az",                     # archive mode, compress
        "--chmod=#{mode.to_s(8)}", # set permissions
        "-e", rsync_ssh_command(control_path, identity_file, port),
        local_path,
        "#{user}@#{host}:#{remote_path}",
      ]

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = TimingProfile.measure("transport.rsync", "transport") do
        Process.run(
          rsync_cmd[0],
          rsync_cmd[1..],
          output: out_io,
          error: err_io
        )
      end

      if result.exit_code? == 0
        @@stats["files_uploaded"] += 1
        true
      else
        false
      end
    end

    # Batch upload multiple files using rsync (most efficient)
    # Returns true if successful, false if rsync not available or failed
    def self.rsync_upload_batch(
      host : String,
      user : String,
      local_files : Array(String),
      remote_dir : String,
      port : Int32? = nil,
      mode : Int32 = 0o755,
      identity_file : String? = nil,
    ) : Bool
      init

      return false if local_files.empty?
      return false unless rsync_available?

      control_path = get_control_path(host, user, port)

      # rsync accepts multiple sources for one destination directory
      # natively - one process spawn (and one SSH session) for the whole
      # batch instead of one per file.
      rsync_cmd = [
        "rsync",
        "-az",
        "--chmod=#{mode.to_s(8)}",
        "-e", rsync_ssh_command(control_path, identity_file, port),
      ] + local_files + ["#{user}@#{host}:#{remote_dir}/"]

      result = TimingProfile.measure("transport.rsync", "transport") do
        Process.run(
          rsync_cmd[0],
          rsync_cmd[1..],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        )
      end

      if result.exit_code? == 0
        @@stats["files_uploaded"] += local_files.size
        true
      else
        false
      end
    end

    # Close specific connection
    def self.close_connection(host : String, user : String, port : Int32? = nil) : Nil
      control_path = get_control_path(host, user, port)

      # Send exit command to close the master connection
      if File.exists?(control_path)
        Process.run(
          "ssh",
          ["-o", "ControlPath=#{control_path}", "-O", "exit", "#{user}@#{host}"],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        )

        # Clean up socket file
        File.delete(control_path) if File.exists?(control_path)
      end
    end

    # Close all connections
    def self.close_all : Nil
      return unless Dir.exists?(@@control_path_dir)

      # Remove all control sockets
      Dir.glob("#{@@control_path_dir}/*").each do |socket_path|
        File.delete(socket_path) if File.exists?(socket_path)
      end
    end

    # Memoized per (host, user, port) - the gsub-over-a-regex result never
    # changes for the same triple, and every exec/upload/download/rsync
    # call on a host recomputes it.
    @@control_path_cache = Hash({String, String, Int32?}, String).new

    # Get control socket path for connection pooling. *port* may be nil
    # (unspecified - ssh resolves it), which keys separately from an
    # explicit 22 so the two never share a socket.
    private def self.get_control_path(host : String, user : String, port : Int32?) : String
      @@control_path_cache.fetch({host, user, port}) do
        # Create a unique socket path for this connection
        # Format: /tmp/.krikri-playbook-ssh/user@host:port
        socket_name = "#{user}@#{host}:#{port}".gsub(/[^a-zA-Z0-9@:.-]/, "_")
        @@control_path_cache[{host, user, port}] = "#{@@control_path_dir}/#{socket_name}"
      end
    end

    # `-i <path>` args for ssh/scp when the inventory specifies
    # ansible_ssh_private_key_file - omitted entirely so ssh falls back to
    # its own default identities/agent, matching real Ansible/OpenSSH
    # behavior when no key is given.
    # Also carries --ssh-common-args/--ssh-extra-args, because every ssh
    # (and scp) invocation in this file already routes through here -
    # making this the one place a CLI-supplied ssh argument has to be
    # added, rather than five.
    # StrictHostKeyChecking value for every ssh/rsync invocation in this
    # file. Defaults to "accept-new" (auto-trust a NEW host key, but
    # still refuse a CHANGED one) - safe for non-interactive use without
    # silently masking a real MITM/key-rotation surprise. Real Ansible's
    # `host_key_checking = False` (ansible.cfg `[defaults]`, or the
    # ANSIBLE_HOST_KEY_CHECKING/ANSIBLE_SSH_HOST_KEY_CHECKING env vars -
    # verified in ansible-core's own ssh.py connection plugin:
    # `if self.get_option('host_key_checking') is False: b_args = (b"-o",
    # b"StrictHostKeyChecking=no")`) is explicitly MORE permissive than
    # this engine's own default - it accepts a CHANGED key too, which
    # matters for exactly the scenario that surfaced this: an ephemeral
    # cloud host whose IP got reused with a different host key from an
    # earlier run still in this machine's known_hosts. This engine has
    # no ansible.cfg INI parsing at all (see krikri-playbook.cr's own
    # show_custom_stats comment for why - env-var-only by design), so
    # only the env var forms are honored here, matching how every other
    # env-var-only setting in this codebase already works.
    private def self.strict_host_key_checking : String
      value = ENV["ANSIBLE_HOST_KEY_CHECKING"]? || ENV["ANSIBLE_SSH_HOST_KEY_CHECKING"]?
      return "accept-new" unless value
      ["no", "false", "0", "off"].includes?(value.downcase) ? "no" : "accept-new"
    end

    private def self.identity_args(identity_file : String?) : Array(String)
      base = identity_file ? ["-i", identity_file] : [] of String
      base + CliOptions.extra_ssh_args
    end

    # Same as identity_args, but as a string fragment for rsync's `-e`
    # ssh command line (which is a single shell-quoted string, not an
    # argv array).
    private def self.identity_ssh_opt(identity_file : String?) : String
      parts = [] of String
      parts << " -i #{shell_quote(identity_file)}" if identity_file
      CliOptions.extra_ssh_args.each { |arg| parts << " #{shell_quote(arg)}" }
      parts.join
    end

    # The `-e` value both rsync paths in this file build - shared so the
    # nil-port omission (no -p; ssh's own config resolution applies)
    # stays identical in both.
    private def self.rsync_ssh_command(control_path : String, identity_file : String?, port : Int32?) : String
      base = "ssh -o ControlMaster=auto -o ControlPath=#{control_path} -o ControlPersist=600" \
             " -o ConnectTimeout=#{CliOptions.timeout} -o StrictHostKeyChecking=#{strict_host_key_checking}" \
             "#{identity_ssh_opt(identity_file)}"
      port ? "#{base} -p #{port}" : base
    end

    # Properly quote a string for shell execution - shared implementation
    # in ./shell.cr (was its own copy, drift risk for a security-relevant
    # primitive).
    private def self.shell_quote(str : String) : String
      Shell.single_quote(str)
    end
  end
end
