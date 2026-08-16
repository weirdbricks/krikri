require "process"
require "file_utils"

# Local Executor - Executes commands locally without SSH
# Used when ansible_connection=local or host is localhost with local connection
module CrystalPlay
  class LocalExecutor
    # How long to keep draining stdout/stderr after the process itself has
    # already exited, before giving up on a pipe that hasn't reached EOF.
    #
    # Passing output/error as a plain IO (as this used to) makes
    # Process#wait itself block until BOTH the process exits AND its
    # stdout/stderr pipes reach EOF - which requires every process holding
    # a duplicate of the pipe's write end to close it, not just the direct
    # child. A shell command shaped like `sleep N && daemon &` backgrounds
    # a *shell* that blocks in its own wait() on `daemon` (a trailing `&`
    # backgrounds the whole `&&`-list, and `nohup` only suppresses
    # SIGHUP - it doesn't exempt a child from its parent's wait()), so if
    # `daemon` never exits, neither does that shell, and the pipe it's
    # still holding open never reaches EOF - hanging this call forever even
    # though the actual process we spawned already finished.
    #
    # Using Process::Redirect::Pipe instead and managing our own drain
    # fibers lets us wait for the process's own exit independently of the
    # pipes, then give any already-buffered output a short, bounded window
    # to be read before force-closing the pipes and moving on - a real
    # command's own output is already fully written into the pipe's kernel
    # buffer by the time it exits, so this window only matters for
    # draining that tail, not for waiting on an unrelated backgrounded
    # process that was never supposed to be waited on in the first place.
    DRAIN_GRACE_PERIOD = 200.milliseconds

    # Any of these anywhere in the command string means it actually needs
    # shell semantics (pipes, redirection, substitution, globbing, home-dir
    # expansion, escaping, sequencing) - real Ansible's own local/ssh
    # connection plugins make the same call (`_low_level_execute_command`'s
    # `executable` handling). Absent all of these, splitting into argv and
    # exec'ing directly is behaviorally identical to `bash -c` but skips
    # forking a whole extra shell process per command.
    SHELL_METACHARACTERS = /[|<>&;`$*?\[\]{}~\\\n]/

    # `needs_shell?` is a pure function of the command string, and the same
    # command is often re-run many times (idempotency reruns, spec suites,
    # loop: bodies) - cache the verdict rather than re-scanning every call.
    @@needs_shell_cache = Hash(String, Bool).new

    private def self.needs_shell?(command : String) : Bool
      @@needs_shell_cache.fetch(command) do
        # A blank command is a no-op under `bash -c ""` (exit 0, no
        # output); Process.parse_arguments would hand back an empty argv
        # and crash on argv[0], so route it through the shell path too.
        result = command.blank? || SHELL_METACHARACTERS.matches?(command)
        @@needs_shell_cache[command] = result
        result
      end
    end

    # Execute command locally
    def self.exec(command : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      # Passing argv directly (no shell: true) skips the extra sh -> bash
      # hop a shell-escaped string would need, and needs no quote-escaping
      # since the command travels as a single argv element, not a string
      # a shell has to re-parse. Only takes this path when the command has
      # no shell metacharacters at all - anything else (a real pipeline,
      # `export K=V; ...` env prefixing, glob, etc.) still needs `bash -c`
      # for correct semantics.
      process =
        if needs_shell?(command)
          Process.new(
            "/bin/bash",
            ["-c", command],
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe
          )
        else
          argv = Process.parse_arguments(command)
          Process.new(
            argv[0],
            argv[1..],
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe
          )
        end

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdout_pipe = process.output
      stderr_pipe = process.error
      stdout_done = drain(stdout_pipe, stdout)
      stderr_done = drain(stderr_pipe, stderr)

      exit_status = process.wait
      await(stdout_pipe, stdout_done)
      await(stderr_pipe, stderr_done)

      {
        exit_code: exit_status.exit_code,
        stdout:    stdout.to_s,
        stderr:    stderr.to_s,
      }
    rescue ex
      {
        exit_code: 1,
        stdout:    "",
        stderr:    "Local execution failed: #{ex.message}",
      }
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
    private def self.await(pipe : IO::FileDescriptor, done : Channel(Nil))
      select
      when done.receive
      when timeout(DRAIN_GRACE_PERIOD)
        pipe.close rescue nil
        done.receive
      end
    end

    # Copy file locally
    def self.copy_file(src : String, dest : String)
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
