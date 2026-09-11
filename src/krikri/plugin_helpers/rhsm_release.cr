require "json"

module Krikri
  module PluginHelpers
    # RhsmRelease - pure logic for the rhsm_release plugin: the real
    # module's release-value regex (release_matcher, lifted verbatim) and
    # the set/unset command construction. Split out so the argv/parse
    # logic is unit-spec-able (the execution path needs a real registered
    # RHEL system).
    module RhsmRelease
      # Matches release-like values such as 7.2, 5.10, 6Server, 8 but
      # rejects unlikely values like 100Server, 1.100, 7server - the
      # real module's own release_matcher, transliterated.
      RELEASE_REGEX = /\b\d{1,2}(?:\.\d{1,2}|Server|Client|Workstation|)\b/

      # First release-like match in `subscription-manager release --show`
      # output, or nil when the release is unset (the real module's
      # get_release: no match -> None).
      def self.current_release(show_output : String) : String?
        RELEASE_REGEX.match(show_output).try(&.[0])
      end

      # At-least-release-shaped validation the real module runs on the
      # target release before touching subscription-manager.
      def self.valid_release?(release : String) : Bool
        !RELEASE_REGEX.match(release).nil?
      end

      # set/unset argv: nil release -> --unset, else --set <release>.
      def self.set_arguments(release : String?) : String
        release ? "release --set #{release}" : "release --unset"
      end
    end
  end
end
