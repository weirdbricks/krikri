require "json"
require "../unsafe_values"
require "../base_action_plugin"
require "../param_sentinels"
require "../variable_substitutor"
require "../variable_substitutor/variable_lookup"

module Krikri
  # debug: (ansible.builtin.debug) as a controller-side action plugin -
  # ported verbatim from plugins/debug.cr (see PluginManager::
  # NEEDS_FULL_VARS's own comment for why this and assert: were the only
  # two plugins reading the full vars context in the first place).
  # ansible-core's own debug module has always been action-plugin-only
  # (action/debug.py) - it never had a target-side module at all, so
  # running it as a real remote plugin binary here was itself a
  # divergence from Ansible's own architecture, not just a missed
  # optimization. plugins/debug.cr is kept as a real, working binary for
  # `--async`/manual invocation, but the normal task-execution path never
  # reaches it anymore.
  class DebugActionPlugin < ActionPlugin
    def execute : ActionResult
      msg = @params["msg"]?
      var_name = @params["var"]?

      # A natively typed msg (literal YAML number/bool, or a whole-span
      # `{{ expr }}` evaluated structurally) arrives JSON-encoded behind the
      # NATIVE_TYPED_PREFIX - Ansible keeps that exact type in the result.
      native_msg = native_typed_msg(msg)
      msg = native_msg.as_s? || native_msg.to_json if native_msg

      # msg and var are mutually exclusive in Ansible.builtin.debug -
      # but that check (like every other option check) belongs to the
      # action plugin's own argument-spec validation, which runs on the
      # controller BEFORE this plugin is reached: ArgspecValidator's debug
      # entry carries the (msg, var) mutually-exclusive pair and the real
      # message ("parameters are mutually exclusive: msg|var",
      # live-verified vs 2.19.11), reported with the action-level chain
      # and the callback result's msg-only dump.

      required_verbosity = verbosity_level(@params["verbosity"]?)
      current_verbosity = @params["_verbosity"]?.try(&.to_i?) || 0

      if current_verbosity < required_verbosity
        # Ansible's registered result for a verbosity-skipped debug
        # carries skipped (and skip_reason) but NO msg key at all (live:
        # podman-diff debug_edge_cases D3 - a follow-up
        # `d3.msg | default('none')` prints 'none' on real). The old
        # msg: "skipped" leaked into the registered var.
        return ActionResult.final(result_json(changed: false, failed: false, msg: "", extra: {"skipped" => JSON::Any.new(true)}))
      end

      # Ansible.builtin.debug documents msg as defaulting to
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

      # Ansible's registered debug msg result runs msg, failed, changed
      # (live-verified vs 2.19.11 via `{{ r | to_json }}`).
      final = result_json(false, false, msg.to_s, {"_ansible_verbose_always" => JSON::Any.new(true)},
        key_order: ["msg", "failed", "changed"])
      if (typed = native_msg) && typed.as_s?.nil?
        return ActionResult.final(JSON.parse({
          "changed"                 => false,
          "failed"                  => false,
          "msg"                     => typed,
          "_ansible_verbose_always" => true,
        }.to_json))
      end
      ActionResult.final(final)
    end

    # The decoded value behind a NATIVE_TYPED_PREFIX `msg`, or nil for an
    # ordinary string one (or an unparsable payload, which Ansible would
    # never produce - the prefix is only ever written by this engine).
    private def native_typed_msg(msg : String?) : JSON::Any?
      return nil unless msg && msg.starts_with?(Krikri::NATIVE_TYPED_PREFIX)
      JSON.parse(msg[Krikri::NATIVE_TYPED_PREFIX.size..]) rescue nil
    end

    # The task's own `verbosity:` threshold. Ansible's spec types it 'int' and
    # a bool IS an int in Python, so a natively-typed `verbosity: true` is 1
    # (the task then skips unless -v) and `false` is 0. The demoted wire
    # text is the only signal left by the time the plugin runs - a QUOTED
    # "true" is rejected by the spec check upstream and never gets here.
    private def verbosity_level(value : String?) : Int32
      return 0 unless value
      return 1 if value == "true"
      return 0 if value == "false"
      value.to_i? || 0
    end

    private def debug_var(var_name : String) : ActionResult
      var_value = VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
      unless var_value
        return ActionResult.final(result_json(false, false, "", {
          "_ansible_verbose_always" => JSON::Any.new(true),
          # 2.19.11 renders the undefined var's error inline (older releases
          # printed "VARIABLE IS NOT DEFINED!")
          var_name => JSON::Any.new("<< error 1 - #{Krikri.strict_undefined_message(var_name, @vars)} >>"),
        }, key_order: [var_name, "failed", "changed"]))
      end

      # Real debug's var: templates the looked-up value through the
      # Templar (action/debug.py: self._templar.template(...)), so a
      # LAZY var - a play/role `vars:` entry whose own value is an
      # unrendered `{{ ... }}` chain (folded-scalar `expected_ips: >-`
      # wrapping `map('extract', hostvars, ...)` is the real-world
      # shape) - is rendered at debug time, and a templating error
      # inside it (extract on a missing hostvars attribute, a
      # strict-mode undefined reference, ...) fails the task exactly
      # like Ansible aborting the play. This path used to stop at
      # the raw lookup and print the unrendered template string as the
      # "value", letting bad-inventory playbooks run on with an ok:.
      # Unsafe gate (VarSubstitutor.unsafe_root?): a var resolved through an
      # execution-resolved root (registered result / set_fact / fact) is
      # AnsibleUnsafe in ansible-core - printed verbatim, never
      # re-templated. Without this, `debug: var=r.stdout` on a hostile
      # module result whose text looks like a template executed the
      # template on the controller.
      unsafe = VarSubstitutor.unsafe_root?(@vars, var_name)

      begin
        rendered = unsafe ? var_value : render_lazy_templates(var_value)
      rescue ex
        return ActionResult.failure(ex.message || "templating var '#{var_name}' failed")
      end

      # Real debug renders the resolved value as native JSON (a bool
      # stays `true`, an int `0`, an object nested) - live-verified
      # 2026-09-24: `debug: var=r.changed` prints `"r.changed": true`,
      # not a quoted string. Only the unresolvable case is a string.
      # Ansible's registered debug var: result runs the VARIABLE-NAME key,
      # failed, changed (live-verified vs 2.19.11 via `{{ r | to_json }}`).
      ActionResult.final(result_json(false, false, "", {
        "_ansible_verbose_always" => JSON::Any.new(true),
        var_name                  => rendered,
      }, key_order: [var_name, "failed", "changed"]))
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
        return value if UnsafeValues.unsafe_text?(raw)
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

    private def result_json(changed : Bool, failed : Bool, msg : String, extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new, key_order : Array(String)? = nil) : JSON::Any
      ActionResult.plugin_result_json(changed, failed, msg, extra, key_order: key_order)
    end
  end
end
