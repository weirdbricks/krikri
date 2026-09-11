#!/usr/bin/env crystal
# community.general.rhsm_release - sets or unsets the RHSM release version
# via `subscription-manager release`. Ported from community.general's
# rhsm_release module (round 300037: linux-system-roles.rhc uses it;
# previously unavailable -> rc=4 "unavailable modules").
#
# Semantics matching the real module:
# - release given -> `release --set <release>`; release null/omitted ->
#   `release --unset` (the module has no state param - omitting release
#   IS the unset, matching real ansible).
# - The target release is validated against the real module's
#   release_matcher regex before anything runs.
# - Idempotency: current release read from `release --show` (first
#   release-like token, or none when unset); changed only when target !=
#   current.
# - Returns current_release (after any change).
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rhsm_release"

module Krikri
  class RhsmReleasePlugin < BasePlugin
    def execute : PluginResult
      release = @params["release"]?
      release = nil if release.nil? || release.empty?

      if target = release
        unless PluginHelpers::RhsmRelease.valid_release?(target)
          return PluginResult.new(changed: false, failed: true,
            msg: "\"#{target}\" does not appear to be a valid release.")
        end
      end

      bin = "subscription-manager"
      check = remote_exec("command -v #{bin}")
      if check[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to find required executable #{bin} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
      end

      show = remote_exec("export LANGUAGE=C LC_ALL=C; #{bin} release --show")
      if show[:exit_code] != 0
        # The real module lets subscription-manager's own failure surface
        # (its run_command uses check_rc=True) - e.g. unregistered systems.
        return PluginResult.new(changed: false, failed: true,
          msg: show[:stderr].empty? ? show[:stdout] : show[:stderr])
      end

      current = PluginHelpers::RhsmRelease.current_release(show[:stdout])
      target = release
      return PluginResult.new(changed: false, failed: false,
        msg: current.to_s, current_release: current) if target == current

      set = remote_exec("export LANGUAGE=C LC_ALL=C; #{bin} #{PluginHelpers::RhsmRelease.set_arguments(target)}")
      return PluginResult.new(changed: false, failed: true,
        msg: set[:stderr].empty? ? set[:stdout] : set[:stderr]) if set[:exit_code] != 0

      PluginResult.new(changed: true, failed: false,
        msg: "Release set to #{target || "unset"}", current_release: target)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RhsmReleasePlugin.new(config)
plugin.run
