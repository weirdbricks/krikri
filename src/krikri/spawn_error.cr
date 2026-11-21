module Krikri
  # Raised - only for callers that opt in via `raise_spawn_errors:` -
  # when a process could not be spawned at all: pipe setup, argv
  # parsing or Process.new failed before the child ever ran. Distinct
  # from a process that ran and exited nonzero, which keeps returning
  # its real exit code (#704: a spawn failure used to masquerade as
  # exit 1 / 255, and plugins branching on that code - e.g. sysctl
  # probing a live value - took silently wrong branches and reported
  # success).
  class SpawnError < Exception; end

  # The ssh command line itself could not be executed on the controller:
  # the binary `ansible_ssh_executable` names (or plain `ssh`) is missing,
  # not executable, or otherwise un-spawnable. Ansible's ssh connection
  # plugin reports this as a CONTROLLER error, not a connection failure -
  # its subprocess.Popen([ssh, ...]) raising OSError becomes
  # AnsibleError("Unable to execute ssh command line on a controller.")
  # with the OSError chained as its cause, and the task FAILS (recap
  # failed=1, exit 2) instead of going UNREACHABLE (live-verified vs
  # 2.21.6, issue #1683). `errno_detail` carries the chained cause's
  # text, ansible's own OSError repr ("[Errno 2] No such file or
  # directory: b'/nonexistent/ssh'"), which the display splits back out
  # as the block's "<<< caused by >>>" section.
  class SshCommandNotExecutableError < Exception
    getter errno_detail : String

    def initialize(@errno_detail : String)
      super("Unable to execute ssh command line on a controller.")
    end

    # The failed task's msg: the "Task failed: " wrap ansible's executor
    # puts on every controller-side exception, over the brief and the
    # errno cause joined the way _text_utils.concat_message joins an
    # exception chain (trailing ". " stripped off the left side).
    def task_failure_msg : String
      "Task failed: Unable to execute ssh command line on a controller: #{errno_detail}"
    end

    # Builds the error from a local spawn failure of *path*: the errno
    # comes off the exception itself (Crystal's Process.new raises
    # File::NotFoundError with the OS error attached).
    def self.from_spawn_failure(path : String, ex : File::Error) : SshCommandNotExecutableError
      os_error = ex.os_error
      errno = os_error.try(&.value.to_i32) || (File.exists?(path) ? 13 : 2)
      new("[Errno #{errno}] #{errno_string(errno)}: b'#{path}'")
    end

    # Builds the error when the child-ssh a transfer spawns reports its
    # own exec failure (scp's `-S` binary: the child dies before any
    # protocol runs and scp relays "<path>: <strerror>"). No errno rides
    # the stderr, so the controller stateside is probed: the two spawn
    # failures a shell can observe are a missing file (ENOENT) and a
    # present-but-not-executable one (EACCES; a directory among them).
    def self.from_transfer_report(path : String) : SshCommandNotExecutableError
      errno = if File.exists?(path)
                13 # EACCES
              else
                2 # ENOENT
              end
      new("[Errno #{errno}] #{errno_string(errno)}: b'#{path}'")
    end

    # The strerror(3) texts for the errnos a spawn can fail with; libc's
    # full table is not exposed to Crystal, and these cover the shapes an
    # un-spawnable ssh command line actually takes.
    private STRERROR = {
       1 => "Operation not permitted",
       2 => "No such file or directory",
       8 => "Exec format error",
      13 => "Permission denied",
      20 => "Not a directory",
      36 => "File name too long",
      40 => "Too many levels of symbolic links",
    }

    # True when *text* is exactly one of the spawn strerror strings - the
    # discriminator SSHManager's transfer path uses to tell scp's relay of
    # a child-ssh exec failure ("<path>: No such file or directory") from
    # the child ssh's own runtime stderr ("ssh: connect to host ...:
    # Connection refused"), which shares the "ssh: " prefix.
    def self.spawn_errno_string?(text : String) : Bool
      STRERROR.values.includes?(text)
    end

    private def self.errno_string(errno : Int32) : String
      STRERROR[errno]? || "Unknown error #{errno}"
    end
  end

  # Test-only spawn-failure hook for the controller-side Python runners
  # (issue #705): KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE names a counter
  # file; while that file exists with a positive integer, each python3
  # spawn attempt consumes one count and fails with a simulated
  # environment-level error - the same failure class LocalExecutor's
  # KRIKRI_TEST_FORCE_SPAWN_FAILURE hook raises - letting a spec force
  # exactly N transient spawn failures before the real interpreter runs.
  # Read from process ENV like LocalExecutor's hook: the runners spawn
  # in-process with no `env:` parameter to carry it, so specs using it
  # declare exclusive!.
  def self.simulated_python_spawn_failure : Nil
    marker = ENV["KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE"]? || return
    return unless File.exists?(marker)
    remaining = File.read(marker).strip.to_i? || 0
    return if remaining <= 0
    File.write(marker, (remaining - 1).to_s)
    raise IO::Error.new("simulated spawn failure (KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE)")
  end

  # Runs a short-lived controller-side helper process, feeding *stdin*
  # and capturing stdout/stderr, with the same spawn classification as
  # LocalExecutor's #704 rule: only a failure BEFORE the process exists
  # raises Krikri::SpawnError (the simulated-failure hook included);
  # a File::Error - the executable vanished or is bad - returns nil;
  # and anything raised AFTER the process ran keeps the caller's
  # pre-#705 verdict, nil (a wrapper that ran is not a spawn failure).
  # stdin is written in a fiber concurrently with draining
  # stdout/stderr, so a chatty child cannot deadlock a payload larger
  # than the pipe buffer against a full pipe.
  def self.run_captured_helper(python : String, args : Array(String),
                               stdin : String) : NamedTuple(status: Process::Status, stdout: String, stderr: String)?
    process = begin
      simulated_python_spawn_failure
      Process.new(python, args,
        input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
    rescue File::Error
      return nil
    rescue ex
      raise SpawnError.new("Failed to spawn process: #{ex.message}")
    end

    begin
      stdout = ""
      stderr = ""
      done = Channel(Nil).new
      spawn do
        begin
          process.input.print(stdin)
          process.input.flush
        rescue
        ensure
          process.input.close
        end
        done.send(nil)
      end
      spawn do
        begin
          stdout = process.output.gets_to_end
        rescue
        end
        done.send(nil)
      end
      spawn do
        begin
          stderr = process.error.gets_to_end
        rescue
        end
        done.send(nil)
      end
      3.times { done.receive }
      status = process.wait
      {status: status, stdout: stdout, stderr: stderr}
    rescue
      nil
    end
  end
end
