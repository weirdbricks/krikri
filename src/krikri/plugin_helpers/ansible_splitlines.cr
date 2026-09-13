require "json"

module Krikri
  module PluginHelpers
    # AnsibleSplitlines - pure logic matching real Ansible's
    # `stdout_lines`/`stderr_lines` derivation, which is built from Python's
    # `str.splitlines()`, not Crystal's plain `String#split("\n")`. The two
    # differ on exactly the cases that matter for real command output: empty
    # input - Python's splitlines() gives `[]`, Crystal's split gives `[""]`
    # (one empty element) - and any trailing newline, which split() turns
    # into a spurious final empty element that splitlines() never produces.
    # Found via konstruktoid-hardening's "Delete unmanaged UFW rules" task:
    # its `ufw_not_managed` command's `grep -v` legitimately matches nothing
    # (every rule this role adds is tagged "ansible managed" and filtered
    # out), producing empty stdout; `ufw_not_managed.stdout_lines | length > 0`
    # should then gate the whole loop off, but the spurious `[""]` made it
    # loop once with an empty item, running `ufw delete ` with no rule spec
    # at all - which real `ufw` rejects with "ERROR: Invalid syntax".
    #
    # Shared by the plugins that produce stdout/stderr (command, shell - each
    # module that has stdout/stderr sets the *_lines keys itself in real
    # Ansible) AND TaskExecutor's register augmentation (which derives them
    # centrally for results that predate a plugin carrying its own).
    module AnsibleSplitlines
      def self.split(text : String) : Array(String)
        return [] of String if text.empty?

        lines = text.split("\n")
        lines.pop if lines.last?.try(&.empty?)
        lines
      end
    end
  end
end
