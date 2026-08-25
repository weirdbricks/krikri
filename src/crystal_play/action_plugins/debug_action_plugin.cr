require "json"
require "../base_action_plugin"
require "../variable_substitutor/variable_lookup"

module CrystalPlay
  # debug: (ansible.builtin.debug) as a controller-side action plugin -
  # ported verbatim from plugins/debug.cr (see PluginManager::
  # NEEDS_FULL_VARS's own comment for why this and assert: were the only
  # two plugins reading the full vars context in the first place). Real
  # ansible-core's own debug module has always been action-plugin-only
  # (action/debug.py) - it never had a target-side module at all, so
  # running it as a real remote plugin binary here was itself a
  # divergence from real Ansible's own architecture, not just a missed
  # optimization. plugins/debug.cr is kept as a real, working binary for
  # `--async`/manual invocation, but the normal task-execution path never
  # reaches it anymore.
  class DebugActionPlugin < ActionPlugin
    def execute : ActionResult
      required_verbosity = @params["verbosity"]?.try(&.to_i) || 0
      current_verbosity = @params["_verbosity"]?.try(&.to_i) || 0

      if current_verbosity < required_verbosity
        return ActionResult.final(result_json(changed: false, failed: false, msg: "skipped", extra: {"skipped" => JSON::Any.new(true)}))
      end

      msg = @params["msg"]?
      var_name = @params["var"]?

      # Real ansible.builtin.debug documents msg as defaulting to
      # "Hello world!" and prints it for a bare `debug:` task (verified
      # against ansible-core 2.19.4). This is the copy that actually runs
      # for a normal debug task - plugins/debug.cr carries the same
      # default for --async/manual invocation.
      msg = "Hello world!" unless msg || var_name

      unless msg || var_name
        return ActionResult.final(result_json(changed: false, failed: true, msg: "msg or var parameter required"))
      end

      debug_output = if var_name
                       var_value = VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
                       if var_value
                         "#{var_name}: #{format_value(var_value)}"
                       else
                         "#{var_name}: VARIABLE IS NOT DEFINED!"
                       end
                     else
                       msg.to_s
                     end

      ActionResult.final(result_json(changed: false, failed: false, msg: debug_output))
    end

    private def format_value(value : JSON::Any) : String
      case value.raw
      when String
        value.as_s
      when Int64, Int32
        value.as_i64.to_s
      when Float64
        value.as_f.to_s
      when Bool
        value.as_bool.to_s
      when Nil
        "null"
      when Array
        array = value.as_a
        if array.all? { |item| item.as_s? || item.as_i? || item.as_bool? }
          "[" + array.map { |item| format_value(item) }.join(", ") + "]"
        else
          value.to_pretty_json
        end
      when Hash
        value.to_pretty_json
      else
        value.to_s
      end
    end

    private def result_json(changed : Bool, failed : Bool, msg : String, extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : JSON::Any
      ActionResult.plugin_result_json(changed, failed, msg, extra)
    end
  end
end
