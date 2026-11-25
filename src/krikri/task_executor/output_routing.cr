require "colorize"
require "../surrogate_escape"

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

    # Real's Display.warning keeps this exact line in its run-wide `_warns`
    # set, so a run that hits many undecodable bytes still warns once (see
    # #report_non_utf8).
    NON_UTF8_WARNING = "[WARNING]: Non UTF-8 encoded data replaced with \"?\" while displaying text to stdout/stderr."
    @@non_utf8_reported = false

    # The private-use twin SurrogateEscape maps an undecodable byte to.
    TWIN_RANGE = /[\x{F780}-\x{F7FF}]/

    def self.redirect_current_fiber_to(io : IO) : Nil
      @@buffers[Fiber.current] = io
    end

    def self.clear_current_fiber_redirect : Nil
      @@buffers.delete(Fiber.current)
    end

    def self.current_io : IO
      @@buffers[Fiber.current]? || STDOUT
    end

    # Broken-pipe writes must surface as IO::Error for this rescue to
    # work. The entrypoints guarantee that (krikri-playbook.cr and
    # base_plugin.cr for the plugin binaries): Crystal 1.22 moved the
    # stdlib's default signal handlers (Signal::PIPE.ignore included)
    # inside Crystal::System::Signal.setup_default_handlers instead of
    # guaranteeing them before user code, AND made the stdio streams call
    # LibC.exit(141) themselves on an EPIPE write (IO::FileDescriptor's
    # exit_on_broken_pipe, set by from_stdio) - the latter is what made
    # `krikri-playbook playbook.yml | head -2` / `--help | head -1` /
    # quitting out of a pager die silently with 141 on 1.22 instead of
    # raising the catchable IO::Error that, with nothing rescuing it,
    # used to dump a full Crystal stack trace and exit 1.
    #
    # ansible-playbook is silent here and exits 0 (verified against
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

    # Ansible's `Display.display` rewrites every CRLF in a message to a
    # bare LF before writing it ("Some environments, such as Azure
    # Pipelines, render `\r` as an additional `\n`" - ansible-core's own
    # comment for it), and display() is the one choke point every
    # banner, task line, result, warning and `[ERROR]:` block passes
    # through on its way to the terminal. krikri wrote such text
    # verbatim, so a message whose own PAYLOAD carries CRLF came out one
    # byte longer than real's: an unreachable report's ssh stderr
    # (`Warning: Permanently added '[host]:2222' (ED25519) to the list
    # of known hosts.\r\nuser@host: Permission denied (publickey,
    # password).`) rendered as `\r\r\n` on a tty against real's `\r\n`
    # (issue #975, live-verified vs ansible-core 2.21.6).
    def self.normalize_for_display(text : String) : String
      text = text.gsub("\r\n", '\n') if text.includes?("\r\n")
      scrub_undecodable(text)
    end

    # Most result and banner lines arrive colorized (`puts "fatal: ...".
    # colorize(:red)`), and IO#puts only ever calls #to_s on that wrapper -
    # so its payload never reached the String overload above and kept every
    # byte it carried. Real normalizes the whole message at display time,
    # color codes and all (issue #1811).
    def self.normalize_for_display(object : Colorize::Object(T)) : String forall T
      normalize_for_display(object.to_s)
    end

    # Real's stdout/stderr are TextIOWrappers reconfigured with
    # `_replacing_warning_handler` (utils/display.py), so ANY write that
    # carries a character the stream cannot encode - the lone surrogate a
    # surrogateescape decode made of a raw non-UTF-8 byte in a remote
    # command's output - puts "?" in its place and warns once per run:
    # `Non UTF-8 encoded data replaced with "?" while displaying text to
    # stdout/stderr.` A script whose stderr held a 0xFF byte printed it
    # where real printed "?" and printed no warning (issue #1811,
    # live-verified vs ansible-core 2.21.6).
    #
    # Both shapes reach this point: a raw invalid byte (a controller string
    # krikri built from bytes) and SurrogateEscape's twin for one (the wire
    # form plugin results and template content use). One "?" per byte,
    # because CPython's surrogateescape resyncs one byte at a time and each
    # surrogate is its own encoding error.
    def self.scrub_undecodable(text : String) : String
      text = scrub_invalid_utf8(text)
      return text unless text.matches?(TWIN_RANGE)
      report_non_utf8
      text.gsub(TWIN_RANGE, '?')
    end

    def self.scrub_invalid_utf8(text : String) : String
      return text if text.valid_encoding?
      report_non_utf8

      bytes = text.to_slice
      String.build(bytes.size) do |io|
        index = 0
        while index < bytes.size
          if length = SurrogateEscape.valid_sequence_length(bytes, index)
            io.write(bytes[index, length])
            index += length
          else
            io << '?'
            index += 1
          end
        end
      end
    end

    # Real's encoding error handler sits under every console write, not
    # only the ones display() passes through, so the `print` path (which
    # never rewrote CRLF and must not start now) scrubs too.
    def self.scrub_for_print(text : String) : String
      scrub_undecodable(text)
    end

    def self.scrub_for_print(object : T) : T forall T
      object
    end

    def self.scrub_for_print(object : Colorize::Object(T)) : String forall T
      scrub_for_print(object.to_s)
    end

    private def self.report_non_utf8 : Nil
      return if @@non_utf8_reported
      @@non_utf8_reported = true
      STDERR.puts NON_UTF8_WARNING.colorize(:light_magenta)
    end

    def self.non_utf8_reported? : Bool
      @@non_utf8_reported
    end

    def self.reset_non_utf8_report : Nil
      @@non_utf8_reported = false
    end

    def self.normalize_for_display(object : T) : T forall T
      object
    end

    # Writes to the real STDOUT, ignoring any per-fiber redirect. Real's
    # `FAILED - RETRYING` callback line comes from the worker as each
    # attempt fails, BEFORE the task banner: under free/host_pinned
    # ansible's default callback prints that banner lazily, on the task's
    # first RESULT (live-verified vs ansible-core 2.21.6, issue #1472).
    # krikri's free path buffers a host's whole task output and flushes it
    # afterwards, so a redirect-aware write would put the retry lines
    # after the banner - see the retry loop's own call site.
    def self.puts_live(object : T) : Nil forall T
      STDOUT.puts normalize_for_display(object)
    rescue ex : IO::Error
      exit_quietly_if_broken_pipe(ex)
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
  Krikri::OutputRouting.current_io.puts(*objects.map { |object| Krikri::OutputRouting.normalize_for_display(object) })
rescue ex : IO::Error
  Krikri::OutputRouting.exit_quietly_if_broken_pipe(ex)
end

# The `: _` restriction has to match the stdlib's own signature: a bare
# `*objects` makes this a separate overload, so stdlib print (writing
# straight to STDOUT) wins resolution and the redirect silently misses.
def print(*objects : _) : Nil
  Krikri::OutputRouting.current_io.print(*objects.map { |object| Krikri::OutputRouting.scrub_for_print(object) })
rescue ex : IO::Error
  Krikri::OutputRouting.exit_quietly_if_broken_pipe(ex)
end
