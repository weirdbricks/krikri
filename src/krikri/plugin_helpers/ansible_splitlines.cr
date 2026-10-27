require "json"

module Krikri
  module PluginHelpers
    # AnsibleSplitlines - pure logic matching Ansible's
    # `stdout_lines`/`stderr_lines` derivation, which is built from Python's
    # `str.splitlines()`, not Crystal's plain `String#split("\n")`. The two
    # differ on the cases that matter for real command output:
    #
    # - Boundary set: Python splits on the full str.splitlines() set -
    #   "\r\n" as one break, plus single "\n", "\r", "\v" (\x0b), "\f"
    #   (\x0c), \x1c, \x1d, \x1e, \x85 (NEL), U+2028 and U+2029 - while
    #   split("\n") treats every other boundary as ordinary text. The "\r"
    #   case is issue #614: curl's progress meter, written to stderr by a
    #   command task's script (install-sdk.sh's curl fetch), is
    #   carriage-return separated, so Ansible reports each progress stage
    #   as its own *_lines element (with an empty element where a line ends
    #   in "\n" immediately before the first "\r"), and a single element
    #   containing raw "\r"s is a byte-for-byte divergence.
    # - Empty input - Python's splitlines() gives `[]`, Crystal's split
    #   gives `[""]` (one empty element).
    # - Any trailing boundary, which split() turns into a spurious final
    #   empty element that splitlines() never produces - but a boundary
    #   followed by another boundary (or end) still yields its own empty
    #   element, e.g. "a\n\r" -> ["a", ""].
    #
    # Found via konstruktoid-hardening's "Delete unmanaged UFW rules" task:
    # its `ufw_not_managed` command's `grep -v` legitimately matches nothing
    # (every rule this role adds is tagged "ansible managed" and filtered
    # out), producing empty stdout; `ufw_not_managed.stdout_lines | length > 0`
    # should then gate the whole loop off, but the spurious `[""]` made it
    # loop once with an empty item, running `ufw delete ` with no rule spec
    # at all - which real `ufw` rejects with "ERROR: Invalid syntax".
    #
    # Shared by the plugins that produce stdout/stderr (command, shell - each
    # module that has stdout/stderr sets the *_lines keys itself in
    # Ansible) AND TaskExecutor's register augmentation (which derives them
    # centrally for results that predate a plugin carrying its own).
    module AnsibleSplitlines
      # The non-"\r" members of Python's str.splitlines() boundary set; "\r" is
      # tested in `split` alongside them.
      private BOUNDARIES = ['\n', '\v', '\f', '\u001c', '\u001d', '\u001e', '\u0085', '\u2028', '\u2029']

      def self.split(text : String) : Array(String)
        return [] of String if text.empty?

        # "\r\n" is one break in Python, so collapse it before splitting on "\r".
        # Indexing a String by character is O(n) on non-ASCII text, hence the
        # single pass over each_char instead of a while loop over indices.
        lines = [] of String
        current = String::Builder.new
        pending = false
        text.gsub("\r\n", "\n").each_char do |char|
          if char == '\r' || BOUNDARIES.includes?(char)
            lines << current.to_s
            current = String::Builder.new
            pending = false
          else
            current << char
            pending = true
          end
        end
        # A trailing boundary ends the last line without starting an empty one.
        lines << current.to_s if pending
        lines
      end
    end
  end
end
