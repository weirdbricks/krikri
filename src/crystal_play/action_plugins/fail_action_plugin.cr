require "json"
require "../base_action_plugin"

module CrystalPlay
  # fail: (ansible.builtin.fail) as a controller-side action plugin -
  # ported verbatim from plugins/fail.cr. Unconditionally fails; its
  # own when: (evaluated before any action/module ever runs) is what
  # makes real playbooks use it conditionally. plugins/fail.cr is kept
  # as a real, working binary for `--async`/manual invocation.
  class FailActionPlugin < ActionPlugin
    def execute : ActionResult
      msg = @params["msg"]? || @params["fail_msg"]? || "Failed as requested from task"
      ActionResult.final(ActionResult.plugin_result_json(false, true, msg))
    end
  end
end
