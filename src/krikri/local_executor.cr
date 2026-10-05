require "process"
require "file_utils"

# Local Executor - Executes commands locally without SSH
# Used when ansible_connection=local or host is localhost with local connection
module Krikri
  class LocalExecutor
    # How long to keep draining stdout/stderr after the process itself has
    # already exited, before giving up on a pipe that hasn't reached EOF.
    #
    # A shell command shaped like `sleep N && daemon &` backgrounds a *shell*
    # that blocks in its own wait() on `daemon` (a trailing `&` backgrounds
    # the whole `&&`-list, and `nohup` only suppresses SIGHUP - it doesn't
    # exempt a child from its parent's wait()), so if `daemon` never exits,
    # neither does that shell, and the pipe it's still holding open never
    # reaches EOF. Waiting unconditionally for EOF on our pipes would hang
    # this call forever even though the actual process we spawned already
    # finished - so once the process itself has exited, any pipe still not
    # at EOF gets this much grace before being force-closed and abandoned
    # (a real command's own output is already fully written into the pipe's
    # kernel buffer by the time it exits, so this window only matters for
    # draining that tail, plus the rare writer still running in the
    # background that we've chosen not to wait for).
    DRAIN_GRACE_PERIOD = 200.milliseconds

    # Any of these anywhere in the command string means it actually needs
    # shell semantics (pipes, redirection, substitution, globbing, home-dir
    # expansion, escaping, sequencing) - Ansible's own local/ssh
    # connection plugins make the same call (`_low_level_execute_command`'s
    # `executable` handling). Absent all of these, splitting into argv and
    # exec'ing directly is behaviorally identical to `bash -c` but skips
    # forking a whole extra shell process per command.
    SHELL_METACHARACTERS = /[|<>&;`$*?\[\]{}~\\\n]/

    # A leading `NAME=value` token (no metacharacters of its own, so the
    # regex above misses it) is shell env-assignment syntax, not part of
    # argv[0] - `DEBIAN_FRONTEND=noninteractive apt-get install ...`
    # (apt.cr's own real command, no `export`/`;` involved) would
    # otherwise get argv-split with "DEBIAN_FRONTEND=noninteractive" as
    # the executable name and crash with ENOENT. Only checked at the
    # start of the string - `=` inside a later argument (`--opt=value`)
    # is completely ordinary and not env-assignment syntax.
    LEADING_ENV_ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

    # `needs_shell?` is a pure function of the command string, and the same
    # command is often re-run many times (idempotency reruns, spec suites,
    # loop: bodies) - cache the verdict rather than re-scanning every call.
    @@needs_shell_cache = Hash(String, Bool).new

    private def self.needs_shell?(command : String) : Bool
      @@needs_shell_cache.fetch(command) do
        # A blank command is a no-op under `bash -c ""` (exit 0, no
        # output); Process.parse_arguments would hand back an empty argv
        # and crash on argv[0], so route it through the shell path too.
        result = command.blank? ||
                 SHELL_METACHARACTERS.matches?(command) ||
                 LEADING_ENV_ASSIGNMENT.matches?(command)
        @@needs_shell_cache[command] = result
        result
      end
    end

    # *env* carries the task's `environment:` (BasePlugin#remote_exec), applied
    # through the child process's own environment the way Ansible hands
    # the dict to subprocess - never through a string prefix in the command
    # itself, which would put the values in the shell's argv where any local
    # user's `ps` can read them. Crystal merges a non-nil env over this
    # process's inherited environment (nil values unset), which is exactly the
    # overlay the old `export K='V';` prefix produced; with *env* present the
    # shell path is always taken, because the argv fast path resolves argv[0]
    # with execvp against the PARENT's PATH while a `environment: PATH: ...`
    # override must govern the lookup (the shell the child became resolves
    # with its own, overridden PATH - the same semantics the export prefix
    # had).
    def self.exec(command : String, force_shell : Bool = false, env : Hash(String, String)? = nil) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      # Passing argv directly (no shell: true) skips the extra sh -> bash
      # hop a shell-escaped string would need, and needs no quote-escaping
      # since the command travels as a single argv element, not a string
      # a shell has to re-parse. Only takes this path when the command has
      # no shell metacharacters at all - anything else (a real pipeline,
      # `export K=V; ...` env prefixing, glob, etc.) still needs `bash -c`
      # for correct semantics.
      #
      # force_shell skips the argv fast path entirely: the shell module's
      # contract is that the string is ALWAYS interpreted by /bin/sh, even
      # when it is metachar-free - a builtin invocation like
      # `command -v modprobe` has no metacharacters but still only exists
      # as a shell builtin (Ansible's shell module always runs
      # `sh -c <string>`; live-verified 2026-09-15). The command module
      # keeps the fast path - Ansible's command module genuinely
      # execs argv without a shell.
      #
      # The child gets OUR OWN pipe write ends (an IO::FileDescriptor
      # passed as output/error is inherited by the child directly - the
      # same mechanism a `File` redirect uses), and the drain fibers below
      # read from the read ends. This deliberately avoids
      # Process::Redirect::Pipe: Process#wait closes whatever pipe IOs the
      # Process object holds in its own `ensure` block the moment it
      # returns, which can beat a drain fiber that is still mid-read on
      # output the child left buffered in the pipe - the drain dies on
      # "Closed stream" and the capture comes back truncated (observed in
      # CI as an intermittently empty stdout for `echo`-style commands).
      # Process#wait never touches these read ends, so a drain fiber is
      # free to keep reading right up to real EOF or the grace-period
      # abandon in #await below.
      stdout_pipe, stdout_child_end = IO.pipe(write_blocking: true)
      stderr_pipe, stderr_child_end = IO.pipe(write_blocking: true)

      begin
        process =
          if force_shell || env || needs_shell?(command)
            Process.new(
              "/bin/bash",
              ["-c", command],
              env: env,
              output: stdout_child_end,
              error: stderr_child_end
            )
          else
            argv = Process.parse_arguments(command)
            Process.new(
              argv[0],
              argv[1..],
              env: env,
              output: stdout_child_end,
              error: stderr_child_end
            )
          end

        # The parent must not hold the write ends: EOF on a pipe - what the
        # drain fibers wait for - requires every write end to be closed,
        # and the child already owns its inherited copies. (Keeping them
        # here would hang every command on the first #await.)
        stdout_child_end.close
        stderr_child_end.close

        stdout = IO::Memory.new
        stderr = IO::Memory.new
        stdout_done = drain(stdout_pipe, stdout)
        stderr_done = drain(stderr_pipe, stderr)

        # Safe to wait here: with the write ends passed as plain
        # IO::FileDescriptors, Process#wait blocks only until the direct
        # child exits (no internal copy fibers to wait on, unlike a plain
        # `IO` argument, which would reintroduce the backgrounded-daemon
        # hang), and its `ensure close` can only close the write ends -
        # already closed above - never the read ends being drained.
        exit_status = process.wait

        await(stdout_pipe, stdout_done)
        await(stderr_pipe, stderr_done)

        {
          exit_code: signal_safe_exit_code(exit_status),
          stdout:    stdout.to_s,
          stderr:    stderr.to_s,
        }
      ensure
        # Covers both the Process.new failure path (nothing spawned, all
        # four ends still open) and the grace-abandonment path (#await
        # already force-closed a read end; close is idempotent). Without
        # this the read ends would leak an fd per exec on the EOF path,
        # since Process no longer owns them.
        stdout_pipe.close
        stderr_pipe.close
        stdout_child_end.close
        stderr_child_end.close
      end
    rescue ex
      {
        exit_code: 1,
        stdout:    "",
        stderr:    "Local execution failed: #{ex.message}",
      }
    end

    # Process::Status#exit_code raises RuntimeError for a signal-killed
    # process; map that to the conventional 128+signal value instead of
    # crashing the shell/command module's result handling.
    private def self.signal_safe_exit_code(status : Process::Status) : Int32
      if status.normal_exit?
        status.exit_code
      elsif signal = status.exit_signal?
        128 + signal.to_i
      else
        # Unreachable on Unix (a signal-less status is a Normal exit
        # reason); Windows-only fallback, see SSHManager's twin.
        128
      end
    end

    # Copies *pipe* into *buffer* on a separate fiber, signaling completion
    # (whether by real EOF or by #await force-closing the pipe after the
    # grace period) via the returned channel.
    private def self.drain(pipe : IO::FileDescriptor, buffer : IO::Memory) : Channel(Nil)
      done = Channel(Nil).new
      spawn do
        IO.copy(pipe, buffer)
      rescue
        # Either a genuine I/O error, or the pipe was force-closed by
        # #await below - either way there's nothing more to read.
      ensure
        done.send(nil)
      end
      done
    end

    # Waits up to DRAIN_GRACE_PERIOD for a drain fiber to finish. If it
    # hasn't (a backgrounded grandchild is still holding the pipe open),
    # force-closes the pipe to unblock the drain fiber's pending read
    # rather than leaking a fiber blocked on a pipe that will never see
    # EOF, then waits for it to actually finish now that its read has been
    # interrupted.
    private def self.await(pipe : IO::FileDescriptor, done : Channel(Nil)) : Nil
      select
      when done.receive
      when timeout(DRAIN_GRACE_PERIOD)
        pipe.close rescue nil
        done.receive
      end
    end

    # Copy file locally
    def self.copy_file(src : String, dest : String) : Nil
      FileUtils.cp(src, dest)
    end

    # Check if file exists
    def self.file_exists?(path : String) : Bool
      File.exists?(path)
    end

    # Check if directory exists
    def self.dir_exists?(path : String) : Bool
      Dir.exists?(path)
    end
  end
end
