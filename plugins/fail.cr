#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # fail plugin (ansible.builtin.fail) - unconditionally fails the task
  # (its own `when:`, evaluated by the executor before a plugin ever
  # runs, is what makes real playbooks use it conditionally - the module
  # itself takes no condition of its own). Never reports changed, runs
  # identically under check mode (matches Ansible - failing is not
  # a state change to skip).
  #
  # msg carries the task arg's NATIVE type: Ansible's fail ACTION plugin
  # assigns `result['msg'] =
  # self._task.args.get('msg')` verbatim - no str() coercion anywhere -
  # so a non-string YAML literal (the parser marks those; see
  # NON_STRING_PARAM_PREFIX) stays an int/float/bool/None/list/dict in
  # the wire result, the fatal dump AND the registered variable
  # (live-verified vs 2.19.11: `msg: 50` fails with {"msg": 50}, the
  # [ERROR] block renders "Action failed: 50"; `msg:` with no value is
  # args.get's explicit None - {"msg": null}, block "Action failed:
  # None" - NOT the default message, which only applies when the msg
  # key is absent entirely; an empty string is kept as {"msg": ""}).
  class FailPlugin < BasePlugin
    def execute : PluginResult
      if @params.has_key?("msg")
        if native = non_string_param("msg")
          return PluginResult.new(changed: false, failed: true, msg: "", native_msg: native)
        elsif explicit_null_param?("msg")
          return PluginResult.new(changed: false, failed: true, msg: "", native_msg: JSON::Any.new(nil))
        else
          return PluginResult.new(changed: false, failed: true, msg: @params["msg"], include_empty_msg: true)
        end
      end
      PluginResult.new(changed: false, failed: true, msg: "Failed as requested from task")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::FailPlugin.new(config)
plugin.run
