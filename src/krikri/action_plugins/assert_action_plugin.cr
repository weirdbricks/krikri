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
  # plain module rather than the control-node-only action plugin
  # Ansible uses ... there's nothing an action plugin buys here" - true
  # for correctness, but a real remote SSH round trip + upload for every
  # assert: task was a real, avoidable cost). plugins/assert.cr is kept
  # as a real, working binary for `--async`/manual invocation.
  #
  # `quiet:` (bool, default false) is display-only: a passing assert
  # with `quiet: true` still carries `msg` in its result/registered var
  # (live-verified against ansible-core 2.19.4), but the success
  # message is not printed. Ansible implements the same thing by
  # adding `_ansible_verbose_always` when NOT quiet; here a quiet
  # success instead tags the result with `_ansible_quiet: true` (private
  # `_ansible_*` keys are stripped before register, so the registered
  # var shape matches Ansible's exactly either way) and
  # ResultDisplay suppresses the msg for it. Failures report
  # msg/assertion/evaluated_to identically with or without `quiet:`.
  class AssertActionPlugin < ActionPlugin
    # AnsibleModule argspec-validates assert's `quiet:` (type: bool)
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
        return ActionResult.final(Krikri.mark_failed_key_order(
          ActionResult.plugin_result_json(false, true, msg), FAILED_KEY_ORDER_ASSERT))
      end

      that_json = @params["that"]?
      unless that_json
        return ActionResult.final(Krikri.mark_failed_key_order(
          ActionResult.plugin_result_json(false, true, "missing required argument: that"), FAILED_KEY_ORDER_ASSERT))
      end

      conditions = Array(String).from_json(that_json)
      substitutor = VarSubstitutor.new(vars: @vars, host_name: @host.name)

      # raise_undefined: true - Ansible is strict for assert:'s own
      # that: exactly as it is for when:, and reports it with the SAME
      # message ("Error while evaluating conditional: 'x' is undefined"),
      # not as an ordinary "Assertion failed". Live-verified against
      # ansible-core 2.19.12 on Rocky 9.6 (round173, buluma.mount's
      # "assert | Test if item.path in mount_requests is set correctly").
      # A filter/default()/is-defined chain stays lenient, same
      # REGEX_BARE_VAR_REF-shaped boundary as every other strict site.
      #
      # strict: true - ansible-core 2.19 also rejects a non-bool
      # `that:` RESULT outright ("Conditional result (True) was derived
      # from value of type 'int'. Conditionals must have a boolean
      # result."), not just a genuinely undefined reference. This was
      # missing here even though `evaluate_when` (the identical check for
      # `when:`) already passes it - found via mrlesmithjr.postgresql's
      # own preflight.yml: `that: postgresql_version | default(false)`
      # where `postgresql_version` defaults to a real int (14, not a
      # bool) - Ansible fails the whole play at this first task;
      # this plugin silently treated the nonzero int as truthy and let
      # the play continue for 5 more tasks before diverging elsewhere.
      # Both conditional-error rescues carry changed=false (ansible-core 2.19.11 registers changed=false+failed=true+msg for
      # a failed conditional, live-verified; see
      # ActionResult.conditional_error_result_json itself).
      current_index = 0
      begin
        failing = nil.as(String?)
        conditions.each_with_index do |condition, idx|
          current_index = idx
          # Ansible compiles the RAW `that:` item as an expression -
          # no `{{ }}` pre-render - so a delimiter-bearing condition is
          # its "Template delimiters are not supported in expressions"
          # syntax error, not something to render away and then evaluate
          # (chriswayg.mailcow / rockandska.rabbitmq's own assert
          # preflights, rounds 1500413/1500208). Checked before
          # substitution, on the raw text, while the delimiters are
          # still visible.
          if delimiter = ConditionalEvaluator.template_delimiter_error(condition)
            raise ConditionalEvaluator::TemplateDelimiterError.new(delimiter)
          end
          substituted = substitutor.substitute(condition)
          next if ConditionalEvaluator.evaluate(substituted, @vars, strict: true, raise_undefined: true)
          failing = condition
          break
        end
      rescue ex : ConditionalEvaluator::TemplateDelimiterError
        # Same shape as the filter-name failure below: ansible-core
        # 2.19.11 prefixes assert:'s own syntax failure "Task failed: ",
        # registers changed=false+failed=true+msg, and the [ERROR]
        # chain's second Origin points at the failing that: item
        # (_ansible_that_index).
        result = ActionResult.conditional_error_result_json("Task failed: #{ex.message}")
        result.as_h["_ansible_that_index"] = JSON::Any.new(current_index.to_i64)
        return ActionResult.final(result)
      rescue ex : ConditionalEvaluator::UndefinedVariableError
        # ansible-core 2.19.11 prefixes assert:'s undefined-
        # conditional failure with "Task failed: " exactly like its
        # non-bool one (live-verified: `assert: that: x` on an undefined
        # var → fatal msg "Task failed: Error while evaluating
        # conditional: 'x' is undefined").
        result = ActionResult.conditional_error_result_json(
          "Task failed: Error while evaluating conditional: #{ex.message}")
        # which that: item failed - the [ERROR] block's second Origin points at it
        result.as_h["_ansible_that_index"] = JSON::Any.new(current_index.to_i64)
        return ActionResult.final(result)
      rescue ex : VariableSubstitutor::FilterEngine::UnknownFilterError | VariableSubstitutor::UnknownTestError
        # A compile-time-rejected filter/test name in a `that:` item is
        # Ansible's "Syntax error in expression: " failure class, not
        # the undefined-reference one - live-verified vs 2.19.11
        # (`assert: that: "x | version_compare('1', '>=')"` → fatal
        # "Task failed: Syntax error in expression: No filter named
        # 'version_compare'."). Before this rescue the raise escaped
        # the plugin uncaught and killed the whole process (found via
        # adarnimrod.apache's ca-store Assertions preflight).
        result = ActionResult.conditional_error_result_json(
          "Task failed: Syntax error in expression: #{ex.message}")
        result.as_h["_ansible_that_index"] = JSON::Any.new(current_index.to_i64)
        return ActionResult.final(result)
      rescue ex : FilterPluginError | TestPluginError
        # A test/filter plugin's RUNTIME failure inside a `that:` item
        # (the version test's "Version comparison failed: ..." among
        # them) - same framing as the when: side's boundary
        # (executor_run_loop's TestPluginError arm, live-verified there
        # for the kwargs matrix): real registers
        # "Task failed: The test plugin '...' failed: <inner>" with the
        # plain prefix and no conditional wrapper. Probe (real
        # 2.19.11): `assert: that: "'9.3.0' is version('x.y.z', '>=')"`
        # -> fatal msg "Task failed: The test plugin
        # 'ansible.builtin.version' failed: Version comparison failed:
        # '<' not supported between instances of 'int' and 'str'".
        # Before this rescue the raise escaped the plugin uncaught and
        # killed the whole process with a bare Crystal stack dump, no
        # [ERROR] chain and no recap (found via vbotka.freebsd_packages,
        # round 5410000 - the role's collection-version sanity assert).
        result = ActionResult.conditional_error_result_json(
          "Task failed: #{ex.message}")
        result.as_h["_ansible_that_index"] = JSON::Any.new(current_index.to_i64)
        return ActionResult.final(result)
      rescue ex : ConditionalEvaluator::ConditionalBooleanError
        # Ansible's assert: prefixes this specific failure
        # "Task failed: " rather than when:'s own "Error while
        # evaluating conditional: " - verified against the exact
        # message ansible-core 2.19.4 raises for a non-bool `that:`
        # result (mrlesmithjr.postgresql's own `that: postgresql_
        # version | default(false)` with a real int default).
        return ActionResult.final(ActionResult.conditional_error_result_json(
          "Task failed: #{ex.message}"))
      end

      failing ? failure_result(failing) : success_result
    end

    # A condition that evaluated false: the first failing `that:` entry
    # decides the message, and the result echoes it as `assertion` /
    # `evaluated_to` so the callback can dump the failed assertion.
    private def failure_result(failing : String) : ActionResult
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
      ActionResult.final(Krikri.mark_failed_key_order(
        ActionResult.plugin_result_json(false, true, fail_msg, extra), FAILED_KEY_ORDER_ASSERT))
    end

    # Every `that:` condition held. Real assert tags its successful result
    # _ansible_verbose_always so the default callback dumps it (`ok: [host]
    # => {"changed": false, "msg": ...}`); a quiet: success is dumped by
    # nothing and prints a bare `ok: [host]` (both live-verified against
    # ansible-core 2.19.11).
    private def success_result : ActionResult
      success_msg = @params["success_msg"]? || "All assertions passed"
      extra = if true?(@params["quiet"]?)
                {"_ansible_quiet" => JSON::Any.new(true)}
              else
                {"_ansible_verbose_always" => JSON::Any.new(true)}
              end
      # Ansible's registered assert success runs changed, msg, failed
      # (live-verified vs 2.19.11 via `{{ r | to_json }}`).
      ActionResult.final(ActionResult.plugin_result_json(false, false, success_msg, extra,
        key_order: ["changed", "msg", "failed"]))
    end

    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
