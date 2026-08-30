#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # fail plugin (ansible.builtin.fail) - unconditionally fails the task
  # (its own `when:`, evaluated by the executor before a plugin ever
  # runs, is what makes real playbooks use it conditionally - the module
  # itself takes no condition of its own). Never reports changed, runs
  # identically under check mode (matches real Ansible - failing is not
  # a state change to skip).
  class FailPlugin < BasePlugin
    def execute : PluginResult
      msg = @params["msg"]? || @params["fail_msg"]? || "Failed as requested from task"
      PluginResult.new(changed: false, failed: true, msg: msg)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::FailPlugin.new(config)
plugin.run
