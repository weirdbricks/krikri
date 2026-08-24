#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/conditional_evaluator"
require "../src/crystal_play/variable_substitutor"
# jinja_filters.cr registers Crinja's custom test/filter library
# (`regex`, `version`, etc, via `Crinja.test`/`Crinja.filter` at
# top-level require time) into the process-wide Crinja default
# library. The main engine binary pulls this in transitively via
# template_action_plugin.cr, so `when:`/`changed_when:`/etc conditions
# (evaluated inside that same process) see every registered test - but
# `assert:` compiles as its OWN standalone plugin binary (per this
# codebase's one-binary-per-module architecture) and evaluates its
# `that:` conditions through the exact same ConditionalEvaluator ->
# Crinja-delegation fallback WITHOUT ever linking this file in, so an
# `is regex(...)`/`is version(...)`/etc test inside `that:` silently
# rendered to something other than the literal "True" and the
# assertion failed even for a condition that was actually true. Found
# via robertdebock.hashicorp's own assert.yml: `item.name is
# regex('^(consul|...|vault).*')`.
require "../src/crystal_play/jinja_filters"

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

      # Strict-undefined, mirroring AssertActionPlugin (the copy that
      # actually runs for a normal assert: task) - see its comment for
      # the live-verified real-Ansible behavior this matches.
      begin
        failing = conditions.find do |condition|
          substituted = substitutor.substitute(condition)
          !ConditionalEvaluator.evaluate(substituted, @vars, raise_undefined: true)
        end
      rescue ex : ConditionalEvaluator::UndefinedVariableError
        return PluginResult.new(changed: false, failed: true,
          msg: "Error while evaluating conditional: #{ex.message}")
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
