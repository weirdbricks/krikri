require "json"
require "../base_action_plugin"
require "../variable_substitutor/variable_lookup"

module Krikri
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
      msg = @params["msg"]?
      var_name = @params["var"]?

      # msg and var are mutually exclusive in real ansible.builtin.debug -
      # the action plugin fails the task with exactly this message before
      # the verbosity gate or any output happens (verified live via
      # testing/podman-diff/cases/debug_edge_cases.yml: real ansible-core
      # prints fatal "'msg' and 'var' are incompatible options").
      if msg && var_name
        return ActionResult.final(result_json(changed: false, failed: true, msg: "'msg' and 'var' are incompatible options"))
      end

      required_verbosity = @params["verbosity"]?.try(&.to_i) || 0
      current_verbosity = @params["_verbosity"]?.try(&.to_i) || 0

      if current_verbosity < required_verbosity
        # Real Ansible's registered result for a verbosity-skipped debug
        # carries skipped (and skip_reason) but NO msg key at all (live:
        # podman-diff debug_edge_cases D3 - a follow-up
        # `d3.msg | default('none')` prints 'none' on real). The old
        # msg: "skipped" leaked into the registered var.
        return ActionResult.final(result_json(changed: false, failed: false, msg: "", extra: {"skipped" => JSON::Any.new(true)}))
      end

      # Real ansible.builtin.debug documents msg as defaulting to
      # "Hello world!" and prints it for a bare `debug:` task (verified
      # against ansible-core 2.19.4). This is the copy that actually runs
      # for a normal debug task - plugins/debug.cr carries the same
      # default for --async/manual invocation.
      msg = "Hello world!" unless msg || var_name

      unless msg || var_name
        return ActionResult.final(result_json(changed: false, failed: true, msg: "msg or var parameter required"))
      end

      # Real debug's var: result carries the value under the VARIABLE
      # NAME key, not under msg (live: podman-diff debug_edge_cases
      # D1/D4 - `d1.msg` is undefined on real, `d1[varname]` is the
      # value). An unresolvable var: name maps to the literal string
      # "VARIABLE IS NOT DEFINED!" under that same key and the task
      # still SUCCEEDS. _ansible_verbose_always keeps the display dump
      # unconditional (see ResultDisplay's empty-msg branch).
      if var_name
        var_value = VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
        var_output = var_value ? format_value(var_value) : "VARIABLE IS NOT DEFINED!"
        return ActionResult.final(result_json(false, false, "", {
          "_ansible_verbose_always" => JSON::Any.new(true),
          var_name                  => JSON::Any.new(var_output),
        }))
      end

      ActionResult.final(result_json(false, false, msg.to_s, {"_ansible_verbose_always" => JSON::Any.new(true)}))
    end

    private def format_array(value : JSON::Any) : String
      array = value.as_a
      if array.all? { |item| item.as_s? || item.as_i? || item.as_bool? }
        "[" + array.map { |item| format_value(item) }.join(", ") + "]"
      else
        value.to_pretty_json
      end
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
        format_array(value)
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
