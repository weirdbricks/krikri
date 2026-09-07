module Krikri
  # Gives the CURRENT (plugin) process a controlling terminal, so that
  # anything it spawns afterwards can `open("/dev/tty")`.
  #
  # Why this exists: real ansible-core's ssh connection plugin asks for a
  # remote pty on essentially every module invocation - see
  # `plugins/connection/ssh.py`:
  #
  #     use_tty = self.get_option('use_tty')
  #     ...
  #     if not in_data and sudoable and use_tty:
  #         args = ('-tt', self.host, cmd)
  #
  # and `sudoable` is True for ordinary module dispatch (it is only
  # forced False for the internal `dd`-based put_file/fetch_file
  # helpers). So under real Ansible the whole remote process tree - the
  # module, and whatever subprocess a `command:`/`shell:` task spawns -
  # inherits a controlling terminal, and `/dev/tty` is openable there.
  #
  # This engine's `SSHManager` never passes `-t`/`-tt`, deliberately:
  # the same channel carries each plugin's JSON `PluginResult` back to
  # the controller, and a pty would merge stderr into stdout, translate
  # LF to CRLF, and change buffering - i.e. it would risk corrupting the
  # result protocol for all 100+ plugins, on every path (one-shot exec,
  # the `bash -s` batch script, and the length-prefixed persistent
  # daemon pipe alike). So instead of asking ssh for a tty, the process
  # that actually needs one manufactures its own, entirely on the target
  # host and entirely off the transport:
  #
  #   posix_openpt -> setsid -> TIOCSCTTY on the pty slave
  #
  # Nothing about the ssh channel changes: stdin/stdout/stderr of this
  # process are untouched (still the pipes the transport handed us), so
  # the JSON result travels back byte-for-byte as before. The pty is a
  # side channel that only `/dev/tty` opens reach.
  #
  # Found via the Galaxy role `imntreal.smallstep_ca`, whose
  # `command: step ca init ...` task fails under this engine with
  # "error allocating terminal: open /dev/tty: no such device or
  # address" while real ansible-playbook succeeds - the `step` CLI
  # opens /dev/tty unconditionally to render a banner, even when (as
  # there) every credential comes from `--password-file` and it never
  # actually reads from it.
  module ControllingTty
    # Linux asm-generic/ioctls.h. `arg: 0` = don't steal the tty from
    # another session (impossible for a pty we just allocated anyway).
    # Deliberately namespaced here rather than at top level: the
    # `expect` plugin defines its own top-level TIOCSCTTY and both land
    # in the same fat-plugin compilation unit.
    TIOCSCTTY = 0x540E_u64

    # Linux O_NOCTTY - opening a terminal with it must never make that
    # terminal the caller's controlling one as a side effect (only the
    # explicit TIOCSCTTY below is allowed to do that).
    O_NOCTTY = 0o400

    # Crystal's own LibC bindings define VMIN but not VTIME
    # (termios.cr) - Linux's c_cc index for it.
    VTIME = 5

    @@attempted = false
    @@acquired = false
    # Held for the life of the process on purpose. The master keeps the
    # pty alive (so a write to /dev/tty by a child never gets EIO), and
    # the slave keeps a reader-visible endpoint open (so the drain fiber
    # below parks on an empty read instead of spinning on EOF) - both
    # close-on-exec, so neither leaks into any spawned command.
    @@master : IO::FileDescriptor? = nil
    @@slave_fd : LibC::Int = -1

    # Idempotent: safe to call before every spawn, and in particular
    # safe in the `--persistent-daemon` remote half, where one resident
    # process serves many tasks and must only ever do this once.
    #
    # Returns true if this process has a controlling terminal when it
    # returns. Never raises and never changes behavior on failure: if
    # anything here is unavailable (no /dev/ptmx, no permission,
    # already a session leader of a session that lost its tty, a
    # non-Linux target), the caller simply proceeds exactly as it did
    # before this existed.
    def self.ensure : Bool
      return @@acquired if @@attempted
      @@attempted = true
      @@acquired = present? || acquire
    end

    # True if this process already has a controlling terminal - the
    # normal case for `ansible_connection=local` runs from an
    # interactive shell, where the plugin binary inherits the user's own
    # terminal and there is nothing to do.
    def self.present? : Bool
      fd = LibC.open("/dev/tty", LibC::O_RDWR | O_NOCTTY)
      return false if fd < 0
      LibC.close(fd)
      true
    end

    private def self.acquire : Bool
      master_fd = LibC.posix_openpt(LibC::O_RDWR | O_NOCTTY)
      return false if master_fd < 0

      if LibC.grantpt(master_fd) != 0 || LibC.unlockpt(master_fd) != 0
        LibC.close(master_fd)
        return false
      end

      name_ptr = LibC.ptsname(master_fd)
      if name_ptr.null?
        LibC.close(master_fd)
        return false
      end
      slave_name = String.new(name_ptr)

      # TIOCSCTTY only works for a session leader with no controlling
      # terminal. Under ssh this process is a child of the remote
      # `bash`, so setsid() succeeds; under `sudo -n -u <become_user>`
      # with sudo's own pty handling it may already BE the leader, in
      # which case setsid() fails with EPERM and that is fine.
      if LibC.setsid < 0 && LibC.getsid(0) != Process.pid
        LibC.close(master_fd)
        return false
      end

      slave_fd = LibC.open(slave_name, LibC::O_RDWR)
      if slave_fd < 0
        LibC.close(master_fd)
        return false
      end

      LibC.ioctl(slave_fd, TIOCSCTTY, 0)

      unless present?
        LibC.close(slave_fd)
        LibC.close(master_fd)
        return false
      end

      configure_slave(slave_fd)

      # A pty master is a character device, so Crystal's own auto-
      # detection wraps it non-blocking/evented - which is what the
      # drain fiber below needs (a blocking read(2) on a fiber would
      # park the whole thread and deadlock the Process#wait the caller
      # is about to do). Both ends are close-on-exec so neither fd
      # leaks into the spawned command.
      master = IO::FileDescriptor.new(master_fd)
      master.close_on_exec = true
      LibC.fcntl(slave_fd, LibC::F_SETFD, LibC::FD_CLOEXEC)
      @@master = master
      @@slave_fd = slave_fd

      # A pty's line discipline holds only a few KB. Nothing on the
      # controller ever reads this side (real Ansible's equivalent
      # bytes end up mixed into ssh's stdout and are discarded when the
      # module's JSON is parsed out of it), so without a reader a
      # program that writes more than that to /dev/tty would block
      # forever. Drain and discard.
      spawn drain(master)

      true
    end

    private def self.drain(master : IO::FileDescriptor) : Nil
      buffer = Bytes.new(4096)
      loop do
        break if master.read(buffer) == 0
      end
    rescue
      # Master closed / EIO at process teardown - nothing to do.
    end

    # Canonical-mode ICANON with the default VMIN=1 would make a read of
    # /dev/tty block forever waiting for a line nobody will ever type.
    # Real Ansible's remote pty is fed by ssh from a controller stdin
    # that is closed, so a read there sees EOF rather than hanging;
    # VMIN=0/VTIME=0 is the closest local equivalent - a read returns 0
    # immediately instead of blocking. ECHO off for the same reason
    # `expect` turns it off: nothing should be echoed back into the
    # stream we are discarding.
    private def self.configure_slave(slave_fd : LibC::Int) : Nil
      termios = uninitialized LibC::Termios
      return unless LibC.tcgetattr(slave_fd, pointerof(termios)) == 0

      termios.c_lflag &= ~((LibC::ICANON | LibC::ECHO).to_u32)
      termios.c_cc[LibC::VMIN] = 0_u8
      termios.c_cc[VTIME] = 0_u8
      LibC.tcsetattr(slave_fd, LibC::TCSANOW, pointerof(termios))
    end
  end
end

lib LibC
  fun posix_openpt(flags : Int) : Int
  fun grantpt(fd : Int) : Int
  fun unlockpt(fd : Int) : Int
  fun ptsname(fd : Int) : Char*
  fun getsid(pid : PidT) : PidT
  # Signatures deliberately identical to the ones plugins/expect.cr
  # declares - both files land in the same fat-plugin compilation unit,
  # where a differing signature for the same fun would not compile.
  fun setsid : PidT
  fun ioctl(fd : Int, request : ULong, arg : Int) : Int
end
