require "process"

# Retry a fork/exec that fails with ETXTBSY ("Text file busy").
#
# The kernel refuses to exec a file while ANY process in the system holds
# it open for writing. In a single-threaded program the writer closes it
# before spawning, so this never comes up; in a concurrent one the window
# is a fork-to-exec gap of microseconds - the writer's own fork inherits
# the (still open) write fd, and our exec lands while that unrelated child
# has not exec'd (or closed the fd) yet. Seen live in the full suite:
# ./inventory_parser_spec/dynamic-inventory: Text file busy, a test that
# writes an executable script and runs it while another fiber forks. It is
# a property of the kernel, not of any one test or engine code path: any
# code that writes a script and then runs it can hit it, on the controller
# or inside a plugin.
#
# Go hit the same thing in cmd/go (golang/go#22315) and its fix is a short
# exponential backoff starting at 100ms; krikri uses 10ms doubling, since
# the window here is only a fork-to-exec gap.
#
# Hooked at Crystal::System::Process.spawn - the single stdlib method behind
# every Unix Process.new / Process.run (all overloads, block forms
# included)
# (see src/process.cr and src/crystal/system/unix/spawn.cr, which reports
# the child's post-exec errno back over a pipe and raises from here). One
# definition therefore covers every Process spawn in src/, plugins/ and the
# test suite, the same way test/minitest_helper.cr hooks Process#io_to_fd
# rather than each call site. Only ETXTBSY is retried (matched on the
# Errno, never on the message text); every other spawn error raises
# immediately, unchanged.
{% unless flag?(:win32) %}
  struct Crystal::System::Process
    # Total spawn attempts, i.e. the first try plus four retries.
    SPAWN_ETXTBSY_ATTEMPTS = 5
    # Delay before the first retry; doubles for each subsequent one
    # (10, 20, 40, 80ms - 150ms total, far longer than the race it covers
    # but still a blip for a spawn that is about to succeed).
    SPAWN_ETXTBSY_BACKOFF = 10.milliseconds

    def self.spawn(prepared_args, shell, env, clear_env, input, output, error, chdir, &)
      attempt = 0
      loop do
        begin
          return previous_def(prepared_args, shell, env, clear_env, input, output, error, chdir) do |errno, command|
            yield errno, command
          end
        rescue ex : ::IO::Error
          raise ex unless ex.os_error == Errno::ETXTBSY
          attempt += 1
          raise ex if attempt >= SPAWN_ETXTBSY_ATTEMPTS
          sleep SPAWN_ETXTBSY_BACKOFF * (1 << (attempt - 1))
        end
      end
    end
  end
{% end %}
