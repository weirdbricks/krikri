require "json"
require "../base_action_plugin"
require "../variable_substitutor"
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
      return debug_var(var_name) if var_name

      ActionResult.final(result_json(false, false, msg.to_s, {"_ansible_verbose_always" => JSON::Any.new(true)}))
    end

    private def debug_var(var_name : String) : ActionResult
      var_value = VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
      unless var_value
        return ActionResult.final(result_json(false, false, "", {
          "_ansible_verbose_always" => JSON::Any.new(true),
          var_name                  => JSON::Any.new("VARIABLE IS NOT DEFINED!"),
        }))
      end

      # Real debug's var: templates the looked-up value through the
      # Templar (action/debug.py: self._templar.template(...)), so a
      # LAZY var - a play/role `vars:` entry whose own value is an
      # unrendered `{{ ... }}` chain (folded-scalar `expected_ips: >-`
      # wrapping `map('extract', hostvars, ...)` is the real-world
      # shape) - is rendered at debug time, and a templating error
      # inside it (extract on a missing hostvars attribute, a
      # strict-mode undefined reference, ...) fails the task exactly
      # like real Ansible aborting the play. This path used to stop at
      # the raw lookup and print the unrendered template string as the
      # "value", letting bad-inventory playbooks run on with an ok:.
      begin
        rendered = render_lazy_templates(var_value)
      rescue ex
        return ActionResult.failure(ex.message || "templating var '#{var_name}' failed")
      end

      # Real debug renders the resolved value as native JSON (a bool
      # stays `true`, an int `0`, an object nested) - live-verified
      # 2026-09-24: `debug: var=r.changed` prints `"r.changed": true`,
      # not a quoted string. Only the unresolvable case is a string.
      ActionResult.final(result_json(false, false, "", {
        "_ansible_verbose_always" => JSON::Any.new(true),
        var_name                  => rendered,
      }))
    end

    # Render lazy `{{ ... }}` template strings inside a looked-up var
    # value (recursively - real Templar.template templates containers
    # element-by-element too). Strings without any `{{` pass through
    # untouched; the render deliberately lets exceptions propagate to
    # the caller, which turns them into a failed task.
    private def render_lazy_templates(value : JSON::Any) : JSON::Any
      case value.raw
      when String
        raw = value.as_s
        return value unless raw.includes?("{{")
        JSON::Any.new(VarSubstitutor.new(vars: @vars, host_name: @host.name).substitute(raw))
      when Array
        JSON::Any.new(value.as_a.map { |item| render_lazy_templates(item) })
      when Hash
        rendered = Hash(String, JSON::Any).new
        value.as_h.each { |key, item| rendered[key] = render_lazy_templates(item) }
        JSON::Any.new(rendered)
      else
        value
      end
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
