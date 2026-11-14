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

      # Ansible's own debug action takes the var: branch only when the
      # argument is PYTHON-TRUTHY (its `if raw_var_arg := new_module_args
      # ['var']` check), so a null var - a bare `var:` with no value, or
      # a block-tag template that rendered nothing and is therefore None,
      # both of which ride this wire as NONE_SENTINEL - and an empty
      # `var: ""` all fall through to the msg side and print debug's
      # "Hello world!" default (live-verified vs 2.21.6). Without this,
      # the sentinel itself became the result KEY and printed as an
      # undefined-variable marker.
      var_name = nil if var_name.try { |v| v.empty? || v == Krikri::NONE_SENTINEL }

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
      # (live-verified vs 2.19.11 via `{{ r | to_json }}`), and an
      # explicitly empty msg stays in that dict (`"msg": ""`) - its
      # exit_json emits the msg key even when the caller passed "" - so the
      # empty key must reach the dump, both for the loop-item and the
      # non-loop case. A NULL msg is the one shape that drops the key
      # entirely: 2.21's UnifiedTaskResult exports msg only when non-None
      # (live-verified vs 2.21.6: both a YAML `msg:` null literal and a
      # templated null register as {changed, failed} with no msg).
      if msg == Krikri::NONE_SENTINEL ||
         ((typed_null = native_msg) && typed_null.raw.nil?)
        return ActionResult.final(JSON.parse({
          "changed"                 => false,
          "failed"                  => false,
          "_ansible_verbose_always" => true,
        }.to_json))
      end
      final = result_json(false, false, msg.to_s, {"_ansible_verbose_always" => JSON::Any.new(true)},
        key_order: ["msg", "failed", "changed"], include_empty_msg: true)
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
      # A natively-typed bool literal demotes to Python str() text
      # ("True"/"False" - see non_string_param_text); the int-typed spec
      # converts the native bool to 1/0 either way.
      return 1 if value == "true" || value == "True"
      return 0 if value == "false" || value == "False"
      value.to_i? || 0
    end

    private def debug_var(var_name : String) : ActionResult
      var_value = VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
      # ansible-core decides what `var:` MEANS by evaluating its raw text as
      # a Jinja EXPRESSION (action/debug.py: evaluate_expression(
      # raw_var_arg)), not by looking the text up as a variable name.
      # hurricanehrndz.sssd's `var: MOLECULE_TESTRUN|default(false)` is a
      # filter chain, so real debug resolves it to false while krikri
      # reported the whole chain as an undefined NAME (issue #970). The
      # bare name/dotted/bracket lookup stays FIRST, since that is what the
      # overwhelming majority of `var:` uses are and its unsafe/lazy-render
      # handling below depends on having resolved a real variable.
      unless var_value
        begin
          # The strict-undefined probe runs BEFORE the lenient evaluation:
          # a chain over an undefined name renders to an empty string there
          # (`nosuch|upper` would print "" instead of real's inline marker),
          # and a `mandatory` chain to a null result where real fails the
          # task. Skipped for an expression that runs a lookup, so the
          # probe's own second evaluation can never re-run a command.
          unless var_name.includes?("lookup(") || var_name.includes?("query(")
            if (undefined_msg = Krikri.strict_undefined_probe_message(var_name, @vars))
              return undefined_var_result(var_name, undefined_msg)
            end
          end
          var_value = VariableSubstitutor::JinjaRenderer.new(@vars).evaluate_value!(var_name)
        rescue ex : Exception
          # A `var` expression that raises (division by zero, a failing
          # filter such as mandatory) fails the task in real debug with
          # this framing rather than printing a marker.
          return ActionResult.failure("Error while resolving `var` expression: #{ex.message}")
        end
      end
      unless var_value
        return undefined_var_result(var_name, undefined_var_message(var_name))
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
      rescue ex : VariableSubstitutor::TemplateSyntaxError
        # Ansible wraps a compile failure of the looked-up value in its
        # `var` expression framing (live-verified, issue #322).
        return ActionResult.failure("Error while resolving `var` expression: #{ex.message}")
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

    # An unresolvable `var:` still SUCCEEDS, carrying 2.19.11's inline error
    # marker under the raw var text (older releases printed "VARIABLE IS
    # NOT DEFINED!"). The marker's origin/excerpt warning block is emitted
    # later by ResultDisplay off this text.
    private def undefined_var_result(var_name : String, undefined_msg : String) : ActionResult
      ActionResult.final(result_json(false, false, "", {
        "_ansible_verbose_always" => JSON::Any.new(true),
        var_name                  => JSON::Any.new("<< error 1 - #{undefined_msg} >>"),
      }, key_order: [var_name, "failed", "changed"]))
    end

    # The name real debug's inline marker quotes for an unresolvable `var:`
    # expression: the failing expression's SOURCE variable ('nosuch' for
    # `nosuch|upper`, live-verified vs 2.21.6), which only the filter-chain
    # probe can name. Every other shape (a bare, dotted or bracket path)
    # keeps the pre-existing root-name wording.
    private def undefined_var_message(var_name : String) : String
      Krikri.undefined_filter_chain_source(var_name, @vars) ||
        Krikri.strict_undefined_message(var_name, @vars)
    end

    # Render lazy template strings inside a looked-up var value
    # (recursively - real Templar.template templates containers
    # element-by-element too). The gate must admit `{% %}`/`{# #}` too:
    # real debug's Templar renders a value that is ONLY a statement block
    # (`a: "{% if true %}yes{% else %}no{% endif %}"` prints yes, issue
    # #1247), and an `{{`-only gate leaked that raw template text.
    # Untemplated strings pass through untouched; the render deliberately
    # lets exceptions propagate to the caller, which turns them into a
    # failed task.
    private def render_lazy_templates(value : JSON::Any) : JSON::Any
      case value.raw
      when String
        raw = value.as_s
        return value if UnsafeValues.unsafe_text?(raw)
        # A `{% do %}` tag fails ansible's compile of the value even when
        # the text has no `{{ }}` span, so the lazy-render gate below must
        # not let it through.
        if (do_error = Krikri::TemplateDoTagScanner.do_tag_error(raw))
          raise VariableSubstitutor::TemplateSyntaxError.new("Syntax error in template: #{do_error}")
        end
        return value unless raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")
        # A string leaf that is WHOLLY one `{{ expr }}` span keeps the
        # expression's structured value: ansible-core's Templar templates
        # container values element-by-element, and a single-span element
        # keeps the result's native type (real: `envfiles_list:
        # ["{{ _envfile_default }}"]` prints as a list HOLDING a dict,
        # never the JSON text substitute collapses it to). The structured
        # evaluation runs through the engine's lazy variable preparation,
        # which renders any template still inside the result - a dict
        # whose values are themselves `{{ other }}` chains (the real
        # role's _envfile_default shape) comes out fully rendered.
        structured = lazy_leaf_structured(raw)
        if structured
          structured
        else
          substituted = VarSubstitutor.new(vars: @vars, host_name: @host.name).substitute(raw)
          # A block-tag template that rendered NO output is a native None in
          # ansible (its Jinja concat returns None when the render produced
          # no nodes), and real debug prints it as null; a whole `{{ '' }}`
          # span keeps the empty string (live-verified 2.21.6) - same split
          # the executor's task-param substitution applies.
          return JSON::Any.new(nil) if substituted.empty? && (raw.includes?("{%") || raw.includes?("{#"))
          JSON::Any.new(substituted)
        end
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

    # nil whenever the structured span evaluation does not apply or the
    # span's own strings bottom out at an undefined reference: the
    # pre-existing lenient substitute above keeps rendering those (a
    # used-that-way undefined decision this fix does not change). A
    # TemplateRecursionError is deliberately NOT rescued - the cycle
    # re-pass through substitute would trip the same guard later, while
    # swallowing it here re-ran a possibly side-effecting resolution
    # looking for a value that cannot exist (see
    # Rerender.re_raise_recursion's rationale).
    private def lazy_leaf_structured(raw : String) : JSON::Any?
      begin
        VariableSubstitutor::Rerender.whole_span_structured(@vars, raw)
      rescue Krikri::UndefinedVariableError
        nil
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

    private def result_json(changed : Bool, failed : Bool, msg : String, extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new, key_order : Array(String)? = nil, include_empty_msg : Bool = false) : JSON::Any
      ActionResult.plugin_result_json(changed, failed, msg, extra, key_order: key_order, include_empty_msg: include_empty_msg)
    end
  end
end
