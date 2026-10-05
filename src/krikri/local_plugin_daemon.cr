require "json"

module Krikri
  # The LOCAL half of the persistent plugin daemon - the exact analogue of
  # `SSHManager`'s daemon half for `ansible_connection=local` tasks, where
  # the "transport" being optimized away is not an ssh client fork but the
  # fat plugin binary's own ~13 ms exec floor (14.8 MB static, measured in
  # ~/scratch/perf-profile-report.md: 30 one-shot local execs were 80% of a
  # 737 ms local-probe wall).
  #
  # Everything here mirrors the ssh daemon's design deliberately, point for
  # point - see `ssh_manager.cr`'s daemon block and `plugin_daemon.cr` for
  # the rationale of each piece; only the mechanics of "spawn the resident
  # process" differ (a direct child of this controller process instead of a
  # remote command over an ssh session):
  #
  # - Same framed stdin/stdout wire protocol (`plugin_daemon.cr` serves it
  #   on the plugin side; `--daemon` on the fat binary).
  # - Same per-connection keying and one-fiber-per-host safety argument:
  #   a local daemon is keyed (host_name, become_user) and only ever
  #   touched by the single fiber that runs that host's tasks - the same
  #   `executor.cr` one-fiber-per-host model the ssh daemon's comment
  #   documents. Unlike ssh there is no (user, port) dimension: every
  #   local connection talks to this controller itself.
  # - Same fallback contract: on any spawn/write/read failure the caller
  #   (PluginManager#try_local_daemon) falls through to the one-fork-per-
  #   task path for THAT task; consecutive failures per key eventually
  #   stop attempting the daemon at all (same MAX_DAEMON_FAILURES=3
  #   threshold, shared from SSHManager); any success resets the count so
  #   a daemon that died once is lazily respawned.
  # - Same dispatch-vs-response-lost classification (the request WAS fully
  #   written, so the module may already have run inside the daemon and
  #   must NOT be re-executed over the fallback - a non-idempotent module
  #   would apply twice): a lost response on a daemon this call spawned
  #   itself is treated as "never came up" and stays fallback-safe, while
  #   one on an already-cached daemon raises
  #   SSHManager::DaemonDispatchUnknownError, which the caller turns into
  #   a failed task via the SAME daemon_dispatch_unknown_result it uses
  #   for the ssh daemon.
  # - Same become handling as the one-shot local path
  #   (#execute_local_plugin_impl): a `become_user` daemon is a separate
  #   keyed daemon spawned through the same `sudo` escalation, with the
  #   same `sudo -n` vs probed `sudo -S -p ''` choice and the password
  #   line written into the stdin pipe ahead of any frame (reusing the
  #   approach `SSHManager.spawn_daemon` documented for the remote side).
  # - Same shutdown at run end: `close_all_daemons` (called from
  #   krikri-playbook.cr right next to SSHManager's) closes each daemon's
  #   stdin - the EOF is the plugin-side clean-shutdown signal - then
  #   polls briefly and force-kills stragglers.
  #
  # Per-request isolation is inherited from the module implementations
  # themselves, exactly as on the ssh daemon: a request's environment:
  # overlay, chdir: and umask are applied by the module code to its own
  # SUBprocesses (Process.new env:/chdir:) or saved/restored around the
  # operation (base_plugin.cr's owner-setting helpers, the openssl_*
  # family) - never mutated on the plugin process itself, which is what
  # makes one long-lived process safe to serve many tasks. The one
  # process-level property the daemon changes vs the one-fork path is
  # therefore only lifetime, not state.
  module LocalPluginDaemon
    # (inventory host name, become_user-or-nil). The host_name dimension
    # keeps the one-fiber-per-host promise: two local-connection hosts are
    # two fibers, so they get two daemons and never share a pipe. A nil
    # become_user is the unprivileged daemon; each distinct become_user
    # gets its own, exactly like SSHManager's table.
    alias LocalDaemonKey = {String, String?}

    @@daemons = Hash(LocalDaemonKey, Process).new

    # Consecutive failures per key, same shape and rationale as
    # SSHManager's own table (a daemon that cannot come up must not cost
    # a wasted spawn attempt on every remaining task). Reset by any
    # success; the threshold is shared so the two transports stay in
    # lockstep.
    @@daemon_failures = Hash(LocalDaemonKey, Int32).new(0)

    # Whether a daemon for this key is worth attempting at all. Public so
    # PluginManager can skip the attempt before resolving a plugin path.
    def self.daemon_unavailable?(host_name : String, become_user : String?) : Bool
      @@daemon_failures[{host_name, become_user}] >= SSHManager::MAX_DAEMON_FAILURES
    end

    # Spec seams, mirroring SSHManager's: install/remove a Process as the
    # cached daemon for a key so the failure-classification logic can be
    # driven against fake processes with no real plugin binary involved.
    def self.seed_daemon_process_for_spec(host_name : String, become_user : String?, process : Process) : Nil
      @@daemons[{host_name, become_user}] = process
    end

    def self.daemon_process_for_spec(host_name : String, become_user : String?) : Process?
      @@daemons[{host_name, become_user}]?
    end

    def self.clear_daemon_for_spec(host_name : String, become_user : String?) : Nil
      kill_daemon(host_name, become_user)
      @@daemon_failures.delete({host_name, become_user})
    end

    # Sends one request and returns the plugin's own JSON result,
    # unwrapped - same contract as SSHManager.daemon_send (the daemon's
    # response IS the plugin's real output; no exit-code arbitration
    # exists on this transport). Failure classification is the ssh
    # daemon's, split by HOW FAR the request got; see its comment for the
    # full rationale - the short version is that the caller's fallback
    # re-EXECUTES the module, so only a provably-undispatched failure may
    # fall through.
    def self.send(
      host_name : String,
      module_name : String,
      config : JSON::Any,
      plugin_path : String,
      become_user : String? = nil,
      become_password : String? = nil,
      timeout : Int32 = SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS,
    ) : JSON::Any
      key = {host_name, become_user}
      # Provenance of the process used below - it decides how a lost
      # response is classified (same rule as SSHManager.daemon_send).
      fresh_spawn = @@daemons[key]?.nil?
      process = @@daemons[key]? ||
                spawn_daemon(host_name, become_user, plugin_path, become_password)

      request = {"module" => module_name, "config" => config}.to_json

      response = TimingProfile.measure("transport.local_daemon_send", "transport") do
        begin
          run_io_with_timeout(timeout) do
            write_daemon_frame(process.input, request)
            ""
          end
        rescue ex
          @@daemon_failures[key] += 1
          kill_daemon(host_name, become_user)
          raise ex
        end

        begin
          run_io_with_timeout(timeout) { read_daemon_frame(process.output) }
        rescue ex
          @@daemon_failures[key] += 1
          kill_daemon(host_name, become_user)
          raise ex if fresh_spawn
          raise SSHManager::DaemonDispatchUnknownError.new("daemon request for '#{module_name}' was sent but its response was lost (#{ex.class.name}: #{ex.message})", ex)
        end
      end

      @@daemon_failures.delete(key)

      begin
        JSON.parse(response)
      rescue ex
        @@daemon_failures[key] += 1
        kill_daemon(host_name, become_user)
        # A response DID arrive and frame cleanly; only its content is
        # unusable. Whatever produced it already ran - never re-execute.
        raise SSHManager::DaemonDispatchUnknownError.new("daemon response for '#{module_name}' was not valid JSON (#{ex.message})", ex)
      end
    end

    # Spawns the resident plugin process. With *become_user* set the
    # daemon runs under the SAME escalation the one-shot local path
    # (#execute_local_plugin_impl) uses for that task - `sudo -n -u <user>
    # --` when passwordless, or `sudo -S -p ''` with the password written
    # into the stdin pipe ahead of any frame - so a host where the
    # one-shot become path works has a daemon that works too, and one
    # where it doesn't fails the same way (loudly, at spawn, then falls
    # back). The password decision is probed once per spawn attempt via
    # PluginManager.sudo_noninteractive? (never with a wrong password -
    # that would feed PAM failure counters), and the framed stdin
    # protocol is untouched: the password line is only prepended when
    # sudo will actually consume it, otherwise it would desynchronize
    # every frame read.
    #
    # STDERR is captured into a throwaway buffer rather than closed or
    # inherited: the one-shot local path captures module stderr per exec
    # (and discards it whenever the result JSON parses), and a module's
    # own crash path (BasePlugin#run_and_capture) writes a backtrace
    # there - a closed fd would turn that write into a SECOND exception
    # inside the daemon and mangle the failed-task JSON, and inheriting
    # would print backtraces to the user's terminal that the one-fork
    # path never showed.
    private def self.spawn_daemon(host_name : String, become_user : String?, plugin_path : String, become_password : String?) : Process
      interactive = false
      if become_user && become_password
        interactive = !PluginManager.sudo_noninteractive?(become_user)
      end

      argv = local_daemon_argv(plugin_path, become_user, interactive)

      process = TimingProfile.measure("transport.local_daemon_spawn", "transport.spawn") do
        Process.new(
          argv[0],
          argv[1..],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: IO::Memory.new
        )
      end

      if interactive && become_password
        process.input.print(become_password)
        process.input.print('\n')
        process.input.flush
      end

      # Cached under the SAME key #send looked up with, so the next request
      # for this (host, become_user) reuses the pipe instead of respawning
      # - the entire point of the transport.
      @@daemons[{host_name, become_user}] = process
      process
    end

    # `sudo` argv for the LOCAL daemon spawn - the same flags the one-shot
    # path's #local_sudo_argv builds (`-n` when passwordless, `-S -p ''`
    # when a password must be read off stdin), plus the trailing
    # `--daemon` that selects the resident mode. No shell is involved
    # (real argv array), so become_user needs no shell-escaping here, same
    # as the one-shot path. Public as a spec seam: pinned directly in the
    # unit tests.
    def self.local_daemon_argv(plugin_path : String, become_user : String?, interactive : Bool) : Array(String)
      return [plugin_path, "--daemon"] unless become_user
      base = interactive ? ["-S", "-p", "", "-u", become_user, "--"] : ["-n", "-u", become_user, "--"]
      base + [plugin_path, "--daemon"]
    end

    private def self.write_daemon_frame(io : IO, payload : String) : Nil
      bytes = payload.to_slice
      io.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(bytes)
      io.flush
    end

    # Same frame-size cap as SSHManager's read side - a garbage length
    # prefix must be refused, not allocated for.
    private def self.read_daemon_frame(io : IO) : String
      length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      raise "daemon frame too large (#{length} bytes)" if length.to_u64 > SSHManager::MAX_DAEMON_FRAME_BYTES
      bytes = Bytes.new(length)
      io.read_fully(bytes)
      String.new(bytes)
    end

    # Same "bound a blocking local pipe op to a wall-clock timeout on a
    # separate fiber" shape as SSHManager's own private copy (that
    # comment's rationale applies verbatim - a local pipe read/write with
    # nothing on the other end is invisible to any keepalive machinery,
    # and there is no SIGKILL escalation here: a daemon is meant to
    # outlive this one call, so a timeout just raises and lets the rescue
    # in #send tear the connection down through #kill_daemon).
    private def self.run_io_with_timeout(timeout_seconds : Int32, &block : -> T) : T forall T
      result_channel = Channel(T).new(1)
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
        raise "local daemon request timed out after #{timeout_seconds}s"
      end
    end

    # Best-effort, no grace period - used from #send's own rescues, where
    # something has already gone wrong and the priority is dropping the
    # stale daemon so the NEXT call spawns a fresh one.
    private def self.kill_daemon(host_name : String, become_user : String?) : Nil
      process = @@daemons.delete({host_name, become_user})
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

    # Graceful shutdown for every still-open local daemon, called once at
    # the end of a run right after SSHManager.close_all_daemons. Same
    # shape as the ssh side's: close every daemon's stdin first (each one
    # sees EOF and exits cleanly via plugin_daemon.cr's own `rescue
    # IO::EOFError`), then poll for the whole batch with the same 1ms ->
    # 20ms doubling backoff inside a 1s hard deadline before force-killing
    # stragglers. The backoff numbers matter for the same measured reason
    # the ssh side's comment records: a daemon sees EOF and exits in about
    # a millisecond, so a flat sleep would burn whole ticks of every run's
    # exit path.
    def self.close_all_daemons : Nil
      processes = @@daemons.values
      @@daemons.clear
      return if processes.empty?

      processes.each do |process|
        begin
          process.input.close
        rescue
        end
      end

      deadline = Time.instant + 1.second
      interval = 1.millisecond
      while Time.instant < deadline
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
  end
end
