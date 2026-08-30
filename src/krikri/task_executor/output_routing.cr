module Krikri
  # Per-fiber stdout/print redirection, used only by TaskExecutor's
  # --forks fan-out (run_task_for_hosts_in_parallel) to buffer each
  # host's output separately, so concurrent hosts' lines never
  # interleave - they're flushed in host order once every fiber for a
  # given task has finished.
  #
  # Safe with no lock: only one fiber ever executes Crystal code at any
  # instant (cooperative scheduling - fibers only yield at explicit I/O
  # waits), so this Hash's mutation and lookup can never actually race,
  # even though several hosts' fibers are "concurrent" from the task
  # executor's point of view. A fiber with no entry here writes straight
  # to the real STDOUT, unchanged from today - this is the path every
  # fiber outside of a --forks fan-out (and the main fiber itself) takes.
  module OutputRouting
    @@buffers = Hash(Fiber, IO).new

    def self.redirect_current_fiber_to(io : IO) : Nil
      @@buffers[Fiber.current] = io
    end

    def self.clear_current_fiber_redirect : Nil
      @@buffers.delete(Fiber.current)
    end

    def self.current_io : IO
      @@buffers[Fiber.current]? || STDOUT
    end

    # Crystal sets SIGPIPE to ignore, so writing to a pipe whose reader
    # has already exited (`krikri-playbook playbook.yml | head -2`,
    # `--version | head -1`, quitting out of a pager) surfaces as an
    # IO::Error instead of quietly killing the process - and, with
    # nothing rescuing it, dumped a full Crystal stack trace to stderr
    # and exited 1.
    #
    # Real ansible-playbook is silent here and exits 0 (verified against
    # ansible-playbook/ansible: `--help | head -1` and
    # `--version | head -1` both produce no stderr and PIPESTATUS[0]=0),
    # so match that. Note this is deliberately NOT fixed by restoring the
    # default SIGPIPE disposition (`Signal::PIPE.reset`): that would let
    # the kernel kill the whole process on ANY EPIPE, including a write
    # to a subprocess stdin that closed early, turning a currently
    # catchable error deep in the SSH/plugin paths into an abrupt death.
    # Scoping it to this program's own stdout writes keeps that behavior
    # unchanged.
    #
    # Every output path in this codebase goes through the puts/print
    # below (there is exactly one other STDOUT reference in the whole
    # tree - current_io above), so this is the complete set of places a
    # stdout EPIPE can originate.
    def self.exit_quietly_if_broken_pipe(ex : IO::Error) : Nil
      raise ex unless ex.os_error == Errno::EPIPE

      # Don't flush-on-exit into the same dead pipe (that would raise
      # again, from at_exit, where nothing can rescue it).
      LibC._exit(0)
    end
  end
end

# Redefines the stdlib's Kernel#puts/#print (which just forward to the
# real STDOUT) to route through Krikri::OutputRouting first. Top-
# level method definitions shadow the stdlib's for the whole program, so
# this must be required before anything that calls puts/print during a
# --forks fan-out - krikri-playbook.cr requires it first, ahead of every
# other require, for exactly that reason.
def puts(*objects) : Nil
  Krikri::OutputRouting.current_io.puts(*objects)
rescue ex : IO::Error
  Krikri::OutputRouting.exit_quietly_if_broken_pipe(ex)
end

def print(*objects) : Nil
  Krikri::OutputRouting.current_io.print(*objects)
rescue ex : IO::Error
  Krikri::OutputRouting.exit_quietly_if_broken_pipe(ex)
end
