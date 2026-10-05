#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/facts_gatherer"

module Krikri
  # GatherFacts Plugin - task-level fact gathering, matching
  # ansible.builtin.gather_facts.
  #
  # Ansible implements `gather_facts` as an ordinary task action
  # (an action plugin that delegates to the setup module) alongside the
  # play-level `gather_facts:` keyword, so a play can re-gather facts
  # mid-play or gather with a different gather_subset/gather_timeout -
  # krikri previously only ever implemented the play-level keyword, so
  # a direct `ansible.builtin.gather_facts: {}` task was skipped and
  # the run exited rc=4 with "unavailable modules:
  # ansible.builtin.gather_facts" where ansible-playbook ran
  # ok=1.
  #
  # This is deliberately distinct from the play-level gathering path
  # (executor_facts_register.cr's gather_facts_for_all_hosts, which
  # calls the facts plugin directly): an explicit task runs THIS plugin
  # through the normal module-dispatch path, exactly like an explicit
  # setup: task does (see SetupPlugin's own comment). Same accepted
  # params and same payload as setup - gather_subset, gather_timeout,
  # filter, fact_path, all flowing through the shared FactsGatherer -
  # and the executor's merge_ansible_facts merges the returned
  # ansible_facts into the host's vars the same way it does for setup.
  class GatherFactsPlugin < BasePlugin
    # Bypasses PluginResult entirely - same reason `setup` does (see
    # SetupPlugin's own comment): the whole-fact-dict serialize-then-
    # reparse of PluginResult's `extra` handling buys nothing here, and
    # real gather_facts' success payload carries no msg. execute()
    # below still exists for the BasePlugin API shape (and the
    # fat-binary generator keys on the class).
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
plugin = Krikri::GatherFactsPlugin.new(config)
plugin.run
