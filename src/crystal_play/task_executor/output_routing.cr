module CrystalPlay
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
  end
end

# Redefines the stdlib's Kernel#puts/#print (which just forward to the
# real STDOUT) to route through CrystalPlay::OutputRouting first. Top-
# level method definitions shadow the stdlib's for the whole program, so
# this must be required before anything that calls puts/print during a
# --forks fan-out - crystal-play.cr requires it first, ahead of every
# other require, for exactly that reason.
def puts(*objects) : Nil
  CrystalPlay::OutputRouting.current_io.puts(*objects)
end

def print(*objects) : Nil
  CrystalPlay::OutputRouting.current_io.print(*objects)
end
