require "json"
require "../base_action_plugin"

module Krikri
  # fail: (ansible.builtin.fail) as a controller-side action plugin -
  # ported verbatim from plugins/fail.cr. Unconditionally fails; its
  # own when: (evaluated before any action/module ever runs) is what
  # makes real playbooks use it conditionally. plugins/fail.cr is kept
  # as a real, working binary for `--async`/manual invocation.
  #
  # msg carries the task arg's NATIVE type: Ansible's action assigns
  # `result['msg'] = self._task.args.get('msg')` verbatim (no str()
  # anywhere), so a non-string YAML literal stays an int/float/bool/
  # None/list/dict in the wire result, the fatal dump AND the registered
  # variable (live-verified vs 2.19.11: `msg: 50` → {"msg": 50}, block
  # "Action failed: 50"; `msg:` with no value is args.get's explicit
  # None → {"msg": null}, block "Action failed: None" - NOT the default
  # message, which only applies when the msg key is absent entirely; an
  # empty string is kept as {"msg": ""}). execute_action opts fail out
  # of the marker strip so the marked literal reaches this plugin intact.
  class FailActionPlugin < ActionPlugin
    def execute : ActionResult
      if @params.has_key?("msg")
        raw = @params["msg"]
        if raw == Krikri::NONE_SENTINEL
          return ActionResult.final(fail_result(JSON::Any.new(nil)))
        elsif native = Krikri.non_string_scalar(raw)
          return ActionResult.final(fail_result(native))
        else
          return ActionResult.final(fail_result(JSON::Any.new(raw)))
        end
      end
      ActionResult.final(Krikri.mark_failed_key_order(
        ActionResult.plugin_result_json(false, true, "Failed as requested from task"),
        FAILED_KEY_ORDER_DEFAULT))
    end

    # The flat result hash with msg ALWAYS present (Ansible's action sets
    # result['msg'] unconditionally - an empty-string msg stays in the
    # registered var and the fatal dump, unlike plugin_result_json's
    # module-side "only when non-empty" rule).
    private def fail_result(msg : JSON::Any) : JSON::Any
      h = Hash(String, JSON::Any).new
      h["changed"] = JSON::Any.new(false)
      h["failed"] = JSON::Any.new(true)
      h["msg"] = msg
      Krikri.mark_failed_key_order(JSON::Any.new(h), FAILED_KEY_ORDER_DEFAULT)
    end
  end
end
