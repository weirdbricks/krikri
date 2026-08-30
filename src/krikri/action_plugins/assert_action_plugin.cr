require "json"
require "../base_action_plugin"
require "../conditional_evaluator"
require "../variable_substitutor"
require "../jinja_filters"

module Krikri
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

      # raise_undefined: true - real Ansible is strict for assert:'s own
      # that: exactly as it is for when:, and reports it with the SAME
      # message ("Error while evaluating conditional: 'x' is undefined"),
      # not as an ordinary "Assertion failed". Live-verified against
      # ansible-core 2.19.12 on Rocky 9.6 (round173, buluma.mount's
      # "assert | Test if item.path in mount_requests is set correctly").
      # A filter/default()/is-defined chain stays lenient, same
      # REGEX_BARE_VAR_REF-shaped boundary as every other strict site.
      #
      # strict: true - real ansible-core 2.19 also rejects a non-bool
      # `that:` RESULT outright ("Conditional result (True) was derived
      # from value of type 'int'. Conditionals must have a boolean
      # result."), not just a genuinely undefined reference. This was
      # missing here even though `evaluate_when` (the identical check for
      # `when:`) already passes it - found via mrlesmithjr.postgresql's
      # own preflight.yml: `that: postgresql_version | default(false)`
      # where `postgresql_version` defaults to a real int (14, not a
      # bool) - real Ansible fails the whole play at this first task;
      # this plugin silently treated the nonzero int as truthy and let
      # the play continue for 5 more tasks before diverging elsewhere.
      begin
        failing = conditions.find do |condition|
          substituted = substitutor.substitute(condition)
          !ConditionalEvaluator.evaluate(substituted, @vars, strict: true, raise_undefined: true)
        end
      rescue ex : ConditionalEvaluator::UndefinedVariableError
        return ActionResult.final(ActionResult.plugin_result_json(
          false, true, "Error while evaluating conditional: #{ex.message}"))
      rescue ex : ConditionalEvaluator::ConditionalBooleanError
        # Real Ansible's assert: prefixes this specific failure
        # "Task failed: " rather than when:'s own "Error while
        # evaluating conditional: " - verified against the exact
        # message ansible-core 2.19.4 raises for a non-bool `that:`
        # result (mrlesmithjr.postgresql's own `that: postgresql_
        # version | default(false)` with a real int default).
        return ActionResult.final(ActionResult.plugin_result_json(
          false, true, "Task failed: #{ex.message}"))
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
