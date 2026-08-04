#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/conditional_evaluator"
require "../src/crystal_play/variable_substitutor"

module CrystalPlay
  # assert plugin (ansible.builtin.assert) - fails (or passes) based on a
  # list of `that:` conditions, for role pre-flight validation.
  #
  # Implemented as a plain module rather than the control-node-only action
  # plugin real Ansible uses (and this entry originally scoped): `that:`
  # conditions only ever reference variables already resolved into @vars
  # (the same full vars_context every other plugin's `params` were already
  # substituted against before this process was even started) - there's no
  # filesystem/network access or controller-vs-target distinction to make,
  # so there's nothing an action plugin buys here that a plain module
  # doesn't already have. Runs and evaluates identically under check mode
  # (real Ansible does the same - the verdict doesn't depend on any state
  # change), never reports changed.
  #
  # Verified against real `ansible-playbook` (not assumed from
  # `ansible-doc`): evaluation stops at the *first* failing condition
  # (conditions are not aggregated), the failed result includes the raw
  # (unsubstituted) `assertion` text and `evaluated_to: false`, the default
  # fail/success messages are exactly `"Assertion failed"` /
  # `"All assertions passed"`, and `msg:` is a real, still-working alias
  # for `fail_msg:` (renamed in Ansible 2.7, alias kept for compat).
  class AssertPlugin < BasePlugin
    def execute : PluginResult
      that_json = @params["that"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: that") unless that_json

      conditions = Array(String).from_json(that_json)
      substitutor = VarSubstitutor.new(vars: @vars, host_name: @host.name)

      failing = conditions.find do |condition|
        substituted = substitutor.substitute(condition)
        !ConditionalEvaluator.evaluate(substituted, @vars)
      end

      if failing
        fail_msg = @params["fail_msg"]? || @params["msg"]? || "Assertion failed"
        PluginResult.new(changed: false, failed: true, msg: fail_msg, assertion: failing, evaluated_to: false)
      else
        success_msg = @params["success_msg"]? || "All assertions passed"
        PluginResult.new(changed: false, failed: false, msg: success_msg)
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::AssertPlugin.new(config)
plugin.run
