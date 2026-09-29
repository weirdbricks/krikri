require "json"
require "../base_action_plugin"
require "../plugin_helpers/strict_bool_params"
require "../conditional_evaluator"
require "../variable_substitutor"
require "../krikri_jinja_filters"

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
  #
  # `quiet:` (bool, default false) is display-only: a passing assert
  # with `quiet: true` still carries `msg` in its result/registered var
  # (live-verified against real ansible-core 2.19.4), but the success
  # message is not printed. Real Ansible implements the same thing by
  # adding `_ansible_verbose_always` when NOT quiet; here a quiet
  # success instead tags the result with `_ansible_quiet: true` (private
  # `_ansible_*` keys are stripped before register, so the registered
  # var shape matches real Ansible's exactly either way) and
  # ResultDisplay suppresses the msg for it. Failures report
  # msg/assertion/evaluated_to identically with or without `quiet:`.
  class AssertActionPlugin < ActionPlugin
    # Real AnsibleModule argspec-validates assert's `quiet:` (type: bool)
    # at module setup - the same StrictBoolValidation the module plugins
    # use, since this action plugin computes the whole result without
    # ever running plugins/assert.cr. Live-verified against ansible-core
    # 2.19.11: `quiet: blah` fails with "argument 'quiet' is of type str
    # and we were unable to convert to bool: The value 'blah' is not a
    # valid boolean. Valid booleans include: ...".
    include PluginHelpers::StrictBoolValidation

    protected def bool_params : Array(String)
      %w[quiet]
    end

    def execute : ActionResult
      if (raw = @params["quiet"]?) &&
         (msg = bool_param_error_msg("quiet", JSON::Any.new(raw)))
        return ActionResult.final(ActionResult.plugin_result_json(false, true, msg))
      end

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
      # Both conditional-error rescues carry changed=false (real
      # ansible-core 2.19.11 registers changed=false+failed=true+msg for
      # a failed conditional, live-verified; see
      # ActionResult.conditional_error_result_json itself).
      current_index = 0
      begin
        failing = nil.as(String?)
        conditions.each_with_index do |condition, idx|
          current_index = idx
          substituted = substitutor.substitute(condition)
          next if ConditionalEvaluator.evaluate(substituted, @vars, strict: true, raise_undefined: true)
          failing = condition
          break
        end
      rescue ex : ConditionalEvaluator::UndefinedVariableError
        # Real ansible-core 2.19.11 prefixes assert:'s undefined-
        # conditional failure with "Task failed: " exactly like its
        # non-bool one (live-verified: `assert: that: x` on an undefined
        # var → fatal msg "Task failed: Error while evaluating
        # conditional: 'x' is undefined").
        result = ActionResult.conditional_error_result_json(
          "Task failed: Error while evaluating conditional: #{ex.message}")
        # which that: item failed - the [ERROR] block's second Origin points at it
        result.as_h["_ansible_that_index"] = JSON::Any.new(current_index.to_i64)
        return ActionResult.final(result)
      rescue ex : ConditionalEvaluator::ConditionalBooleanError
        # Real Ansible's assert: prefixes this specific failure
        # "Task failed: " rather than when:'s own "Error while
        # evaluating conditional: " - verified against the exact
        # message ansible-core 2.19.4 raises for a non-bool `that:`
        # result (mrlesmithjr.postgresql's own `that: postgresql_
        # version | default(false)` with a real int default).
        return ActionResult.final(ActionResult.conditional_error_result_json(
          "Task failed: #{ex.message}"))
      end

      if failing
        fail_msg = @params["fail_msg"]? || @params["msg"]? || "Assertion failed"
        # a bare YAML bool item (`that: [false]`) is reported as the bool itself
        assertion = failing == "false" ? JSON::Any.new(false) : (failing == "true" ? JSON::Any.new(true) : JSON::Any.new(failing))
        extra = {"assertion" => assertion, "evaluated_to" => JSON::Any.new(false)}
        # Real assert tags the FAILURE result _ansible_verbose_always too
        # (its action sets it once up front for any non-quiet run), so
        # the default callback dumps the failed assertion pretty-printed
        # - 4-space indent, sorted keys (live-verified against 2.19.11).
        unless true?(@params["quiet"]?)
          extra["_ansible_verbose_always"] = JSON::Any.new(true)
        end
        ActionResult.final(ActionResult.plugin_result_json(false, true, fail_msg, extra))
      else
        success_msg = @params["success_msg"]? || "All assertions passed"
        if true?(@params["quiet"]?)
          extra = {"_ansible_quiet" => JSON::Any.new(true)}
          ActionResult.final(ActionResult.plugin_result_json(false, false, success_msg, extra))
        else
          # Real assert tags its successful result _ansible_verbose_always
          # so the default callback dumps it (`ok: [host] => {"changed":
          # false, "msg": ...}`); a quiet: success is dumped by nothing
          # and prints a bare `ok: [host]` (both live-verified against
          # ansible-core 2.19.11).
          extra = {"_ansible_verbose_always" => JSON::Any.new(true)}
          ActionResult.final(ActionResult.plugin_result_json(false, false, success_msg, extra))
        end
      end
    end

    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
