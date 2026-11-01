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
