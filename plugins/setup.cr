#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Setup Plugin - gather facts, matching ansible.builtin.setup.
  #
  # This engine gathers facts up front through its own `facts` plugin (via
  # the play's gather_facts / the engine's fact store), which is what
  # populates ansible_facts before tasks run. The `setup` module therefore
  # only needs to (a) be recognized as available and (b) not error - roles
  # gate it with `when: not ansible_facts` so it's skipped exactly when the
  # facts are already present, which is the normal case. When it *does* run
  # on a host that has none (rare), it reports success without fabricating
  # facts, letting any already-passed ansible_facts ride through unchanged.
  class SetupPlugin < BasePlugin
    def execute : PluginResult
      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Facts already gathered"
      )
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SetupPlugin.new(config)
plugin.run
