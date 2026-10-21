# Crystal 1.22 makes STDOUT/STDERR call LibC.exit(141) themselves on an
# EPIPE write (IO::FileDescriptor#exit_on_broken_pipe, set by from_stdio)
# and no longer guarantees SIGPIPE is ignored before user code runs. Both
# would turn a closed reader (`... | head -1`) into a silent death that
# bypasses every rescue; ignore the signal and turn the self-exit off so
# a truncated pipe surfaces as the catchable IO::Error that
# OutputRouting.exit_quietly_if_broken_pipe handles (never Signal::PIPE.reset:
# see output_routing.cr). Toolchains older than 1.22 (e.g. Homebrew's on the
# macOS release builders) have no such setter, hence the has_method? guard.
Signal::PIPE.ignore
{% if IO::FileDescriptor.has_method?("exit_on_broken_pipe=") %}
  STDOUT.exit_on_broken_pipe = false
  STDERR.exit_on_broken_pipe = false
{% end %}
