#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/facts_gatherer"

module Krikri
  # Setup Plugin - gather facts, matching ansible.builtin.setup.
  #
  # This engine gathers facts up front through its own `facts` plugin (via
  # the play's gather_facts / the engine's fact store), which is what
  # populates ansible_facts before tasks run. An EXPLICIT `setup:` task in
  # a playbook/role runs this plugin for real, though - roles re-gather
  # after changes (`when: not ansible_facts` gates aside), and real
  # Ansible's setup accepts four documented module params, all of which
  # now flow through to the shared gatherer:
  #
  #   - gather_subset: comma-separated families (all/min/hardware/network/
  #     mounts/aliases, !-negations, unknown positives fail like real)
  #   - gather_timeout: per-family timeout in seconds (hardware/mounts,
  #     the collectors real Ansible guards; default 10)
  #   - filter: fnmatch glob(s) over top-level fact keys, post-gather
  #   - fact_path: *.fact scripts/ini/json files gathered into ansible_local
  #
  # The result payload is exactly the facts plugin's ("changed"/"failed"/
  # "ansible_facts", no msg on success), so the executor's
  # merge_ansible_facts merges the freshly gathered (and filtered) facts
  # into the host's vars exactly as it does the play's implicit gathering.
  class SetupPlugin < BasePlugin
    # Bypasses PluginResult entirely - same reason `facts` itself was
    # never reshaped into a BasePlugin result (see facts_gatherer.cr):
    # the whole-fact-dict serialize-then-reparse of PluginResult's
    # `extra` handling buys nothing here, and real setup's success
    # payload carries no msg. execute() below still exists for the
    # BasePlugin API shape (and the fat-binary generator keys on the
    # class).
    def run_and_capture : String
      Krikri::FactsGatherer.run(@config)
    end

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
plugin = Krikri::SetupPlugin.new(config)
plugin.run
