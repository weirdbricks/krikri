require "json"
require "../base_action_plugin"
require "../conditional_evaluator"
require "../variable_substitutor"
require "../jinja_filters"

module CrystalPlay
  # assert: (ansible.builtin.assert) as a controller-side action plugin -
  # ported verbatim from plugins/assert.cr. `that:` conditions only ever
  # reference variables already resolved into @vars, exactly like
  # when:/changed_when: - there's no filesystem/network access or
  # controller-vs-target distinction to make, so this closes the gap
  # plugins/assert.cr's own comment already flagged ("Implemented as a
  # plain module rather than the control-node-only action plugin real
  # Ansible uses ... there's nothing an action plugin buys here" - true
  # for correctness, but a real remote SSH round trip + upload for every
  # assert: task was a real, avoidable cost). plugins/assert.cr is kept
  # as a real, working binary for `--async`/manual invocation.
  class AssertActionPlugin < ActionPlugin
    def execute : ActionResult
      that_json = @params["that"]?
      unless that_json
        return ActionResult.final(ActionResult.plugin_result_json(false, true, "missing required argument: that"))
      end

      conditions = Array(String).from_json(that_json)
      substitutor = VarSubstitutor.new(vars: @vars, host_name: @host.name)

      failing = conditions.find do |condition|
        substituted = substitutor.substitute(condition)
        !ConditionalEvaluator.evaluate(substituted, @vars)
      end

      if failing
        fail_msg = @params["fail_msg"]? || @params["msg"]? || "Assertion failed"
        extra = {"assertion" => JSON::Any.new(failing), "evaluated_to" => JSON::Any.new(false)}
        ActionResult.final(ActionResult.plugin_result_json(false, true, fail_msg, extra))
      else
        success_msg = @params["success_msg"]? || "All assertions passed"
        ActionResult.final(ActionResult.plugin_result_json(false, false, success_msg))
      end
    end
  end
end
