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
end
