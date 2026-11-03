require "process"

require "./controlling_tty"

module Krikri
  module PluginHelpers
    # Runs a command with its stdin/stdout/stderr attached to a REAL pty
    # allocated on this host, capturing the merged session output from the
    # master side.
    #
    # Why this exists: real ansible runs a remote `raw:` through `ssh -tt`
    # (ssh.py adds `-tt` to every command that sends no stdin, and raw's
    # action plugin always qualifies), so the remote command's stdout AND
    # stderr arrive on one pty in execution order. The stream merge itself
    # is already emulated (ScriptPtyCapture.pty_merged_command's
    # `{ ...; } 2>&1` group), but a real pty also changes how
    # isatty-sensitive programs BEHAVE, and no post-hoc output shaping can
    # reproduce that: `apt` emits its colored progress meter and suppresses
    # its "does not have a stable CLI interface" warning only when stdout
    # is a tty (issue #775 - dustinrue.xenial-bootstrap's
    # `raw: ... apt -y update ...` captured the progress bar under real and
    # the warning + plain lines under the pipe emulation). The program has
    # to actually see a tty.
    #
    # The plugin process runs on the target host (remote dispatch injects
    # ansible_connection=local), so the pty is allocated right here, the
    # same place real's pty lives - nothing about the transport changes
    # and the JSON result still travels back over clean pipes.
    #
    # Termios stays at the kernel defaults, which is what real's sshd pty
    # gives the command too: OPOST|ONLCR on (every \n the command writes
    # becomes \r\n on the capture, exactly matching the live-verified
    # ansible capture), ECHO on (nothing is ever written to the master, so
    # nothing can be echoed back). The child's stdin is the slave, like
    # real's `ssh -tt` session - a raw command that reads stdin blocks
    # there under real ansible too (the master stays open for the whole
    # session).
    module PtyCommandRunner
      @@available : Bool? = nil

      # Cached once per process (the resident remote daemon serves many
      # tasks): a /dev/ptmx-less target (hardened containers) keeps the
      # plain-pipe capture for every raw task instead of re-probing per
      # task. Probing allocates and immediately closes one pty.
      def self.available? : Bool
        @@available ||= probe
      end

      private def self.probe : Bool
        fd = LibC.posix_openpt(LibC::O_RDWR | ControllingTty::O_NOCTTY)
        return false if fd < 0
        ok = LibC.grantpt(fd) == 0 && LibC.unlockpt(fd) == 0 && !LibC.ptsname(fd).null?
        LibC.close(fd)
        ok
      end

      # Returns nil when no pty could be allocated - always BEFORE anything
      # is spawned, so the caller can fall back to its plain-pipe capture
      # without ever double-executing a side-effectful command. Once the
      # child is spawned a real result always comes back.
      def self.exec(command : String, env : Hash(String, String)? = nil) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)?
        return nil unless available?

        master_fd = LibC.posix_openpt(LibC::O_RDWR | ControllingTty::O_NOCTTY)
        return nil if master_fd < 0

        if LibC.grantpt(master_fd) != 0 || LibC.unlockpt(master_fd) != 0
          LibC.close(master_fd)
          return nil
        end
        name_ptr = LibC.ptsname(master_fd)
        if name_ptr.null?
          LibC.close(master_fd)
          return nil
        end
        slave_fd = LibC.open(String.new(name_ptr), LibC::O_RDWR)
        if slave_fd < 0
          LibC.close(master_fd)
          return nil
        end

        # Evented master reads: a blocking read(2) on a fiber holds the
        # whole scheduler thread, which would starve Process's reaper
        # fiber whenever a backgrounded grandchild keeps the slave open
        # past the command's own exit - the same abandonment tradeoff
        # LocalExecutor makes for pipes, without its deadlock risk.
        master = IO::FileDescriptor.new(master_fd)
        master.close_on_exec = true
        IO::FileDescriptor.set_blocking(master_fd, false)
        slave = IO::FileDescriptor.new(slave_fd)

        output = IO::Memory.new
        spawned = false
        begin
          process = Process.new(
            "/bin/bash",
            ["-c", command],
            env: env,
            input: slave,
            output: slave,
            error: slave
          )
          spawned = true
          # The child owns dup'd copies of the slave now; the parent's copy
          # only has to go so its finalizer cannot close the fd out from
          # under the running session.
          slave.close
          done = drain(master, output)
          status = process.wait
          await_eof(master, done)
          {exit_code: signal_safe_exit_code(status), stdout: output.to_s, stderr: ""}
        rescue ex
          raise ex if spawned
          nil
        ensure
          slave.close unless slave.closed?
          master.close unless master.closed?
        end
      end

      # Process::Status#exit_code raises on a signal-killed process; the
      # same 128+signal mapping every other capture path uses.
      private def self.signal_safe_exit_code(status : Process::Status) : Int32
        if status.normal_exit?
          status.exit_code
        elsif signal = status.exit_signal?
          128 + signal.to_i
        else
          128
        end
      end

      private def self.drain(master : IO::FileDescriptor, buffer : IO::Memory) : Channel(Nil)
        done = Channel(Nil).new
        spawn do
          buf = Bytes.new(8192)
          loop do
            n = master.read(buf)
            break if n == 0
            buffer.write(buf[0, n])
          end
        rescue
          # Master force-closed by #await below (backgrounded grandchild
          # still holding the slave), or EIO at pty teardown.
        ensure
          done.send(nil)
        end
        done
      end

      # Real's `ssh -tt` session ends when the shell exits, and a
      # backgrounded grandchild that keeps the slave open does not extend
      # it - so once the command itself has exited, a capture that hasn't
      # reached EOF gets the same grace-period abandon the plain-pipe path
      # uses rather than hanging the task on a daemon's tty fd.
      private def self.await_eof(master : IO::FileDescriptor, done : Channel(Nil)) : Nil
        select
        when done.receive
        when timeout(LocalExecutor::DRAIN_GRACE_PERIOD)
          master.close rescue nil
          done.receive
        end
      end
    end
  end
end
