require "json"
require "../base_action_plugin"

module Krikri
  # set_fact: (ansible.builtin.set_fact) as a controller-side action
  # plugin - ported verbatim from plugins/set_fact.cr (including the
  # leading-zero-string / Python-repr-dict coercion fixes documented
  # there). Never touches the filesystem or network, so there was never
  # anything a remote round trip bought here either.
  # plugins/set_fact.cr is kept as a real, working binary for
  # `--async`/manual invocation.
  class SetFactActionPlugin < ActionPlugin
    CONTROL_PARAMS = {"cacheable"}

    # real's utils/vars.py validate_variable_name allowlist: a Python
    # str.isidentifier() (ASCII-only enforced here) that is not one of
    # the few Jinja-reserved words.
    JINJA_KEYWORD_KEYS = {"True", "False", "None", "true", "false", "none", "not"}

    def execute : ActionResult
      # real's set_fact action plugin pops `cacheable` and runs it
      # through convert_bool.boolean() with strict=True BEFORE anything
      # else - a value that is not one of real's booleans fails the
      # whole task there. The plain TypeError is not a result-
      # contributing exception, so real's fatal msg is the collapsed
      # chain brief: "Task failed: " + the conversion error.
      if raw = @params["cacheable"]?
        if error = strict_boolean_error(cacheable_native(raw))
          return ActionResult.final(Krikri.mark_failed_key_order(
            ActionResult.plugin_result_json(false, true, "Task failed: #{error}"), FAILED_KEY_ORDER_EXCEPTION_FIRST))
        end
      end

      facts = Hash(String, JSON::Any).new

      @params.each do |key, value|
        # execute_action injects its own engine-wire keys into every
        # action plugin's params (real's _task.args never sees them);
        # they are not user facts and must not satisfy real's
        # no-key/value-pairs check either.
        next if CONTROL_PARAMS.includes?(key) || key == "_verbosity" || key == "_ansible_check_mode"
        # real validates EVERY fact key with validate_variable_name() in
        # insertion order and fails on the first invalid one; the raised
        # AnsibleError contributes no result, so the fatal msg again
        # carries the "Task failed: " brief prefix (the error block's
        # cause segment then points at the key's own Origin with real's
        # help text - see ResultDisplay's emit path).
        unless valid_variable_name?(key)
          return ActionResult.final(Krikri.mark_failed_key_order(
            ActionResult.plugin_result_json(false, true, "Task failed: Invalid variable name '#{key}'."), FAILED_KEY_ORDER_EXCEPTION_FIRST))
        end
        facts[key] = coerce(value)
      end

      if facts.empty?
        # real: AnsibleActionFail - a result-CONTRIBUTING action failure,
        # so the fatal msg carries NO "Task failed: " prefix.
        return ActionResult.final(Krikri.mark_failed_key_order(
          ActionResult.plugin_result_json(false, true, "No key/value pairs provided, at least one is required for this action to succeed"), FAILED_KEY_ORDER_EXCEPTION_FIRST))
      end

      extra = {"ansible_facts" => JSON::Any.new(facts)}
      # Real's registered set_fact result runs ansible_facts, failed,
      # changed (live-verified vs 2.19.11 via `{{ r | to_json }}`).
      ActionResult.final(ActionResult.plugin_result_json(false, false, "", extra,
        key_order: ["ansible_facts", "failed", "changed"]))
    end

    # The executor marks every set_fact param value with
    # NATIVE_TYPED_PREFIX + the JSON encoding of the value's native type
    # (see #coerce) - decode `cacheable` back to that native value so
    # the strict check sees what real's boolean() sees (an int 5 is not
    # a boolean, the float 1.0 is, a bare `esfzey` is the string it
    # looks like).
    private def cacheable_native(raw : String) : JSON::Any
      if raw.starts_with?(Krikri::NATIVE_TYPED_PREFIX)
        begin
          JSON.parse(raw[Krikri::NATIVE_TYPED_PREFIX.size..])
        rescue JSON::ParseException
          JSON::Any.new(raw)
        end
      elsif raw == NONE_SENTINEL
        JSON::Any.new(nil)
      else
        JSON::Any.new(raw)
      end
    end

    # convert_bool.boolean(strict=True) over the value's native type:
    # the boolean spellings real accepts case-insensitively after strip,
    # plus the ints 1/0 and floats 1.0/0.0 (real's BOOLEANS set holds
    # them as numbers - a quoted "1.0" STRING is NOT valid there, but a
    # demoted literal is text this wire cannot distinguish; the native
    # form is the common one).
    private def strict_boolean_error(native : JSON::Any) : String?
      case raw = native.raw
      when Bool
        nil
      when Int64
        return nil if raw == 1 || raw == 0
        value_error(native)
      when Float64
        return nil if raw == 1.0 || raw == 0.0
        value_error(native)
      when String
        normalized = raw.downcase.strip
        return nil if ArgspecValidator::REAL_TRUE.includes?(normalized)
        return nil if ArgspecValidator::REAL_FALSE.includes?(normalized)
        value_error(native)
      else
        value_error(native)
      end
    end

    private def value_error(native : JSON::Any) : String
      "The value '#{python_value_text(native)}' is not a valid boolean. Valid booleans include: #{ArgspecValidator::BOOLEANS_REPR.join(", ")}"
    end

    # to_text(value) for the error message: scalars match real's str()
    # directly; JSON-shaped containers get real's Python str() spacing
    # (", " between items).
    private def python_value_text(native : JSON::Any) : String
      case raw = native.raw
      when Nil            then "None"
      when Bool           then raw ? "True" : "False"
      when Int64, Float64 then raw.to_s
      when Array          then "[" + native.as_a.map { |item| python_scalar_repr(item) }.join(", ") + "]"
      when Hash           then "{" + native.as_h.map { |key, value| "'#{key}': #{python_scalar_repr(value)}" }.join(", ") + "}"
      else                     native.as_s
      end
    end

    private def python_scalar_repr(value : JSON::Any) : String
      case raw = value.raw
      when Bool   then raw ? "True" : "False"
      when String then "'#{raw}'"
      when Nil    then "None"
      else             value.to_s
      end
    end

    private def valid_variable_name?(key : String) : Bool
      return false unless key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      !JINJA_KEYWORD_KEYS.includes?(key)
    end

    private def coerce(value : String) : JSON::Any
      # A whole-single-span `{{ expr }}` fact arrives prefixed with the
      # JSON encoding of the expression's natively-typed result (see
      # substitute_task_params / NATIVE_TYPED_PREFIX): decode it verbatim
      # instead of re-coercing by string shape. Real ansible-core 2.19
      # keeps the expression's own type - a Jinja string expression stays
      # a str even when it looks like a number (pluggero.openssh round
      # 981024: the coerced float made an `!=` version comparison always
      # true, reinstalling openssh every run). Everything else - literal
      # YAML scalars, mixed/multi-span text, block-tag output - keeps the
      # legacy string-shape coercion below.
      if value.starts_with?(Krikri::NATIVE_TYPED_PREFIX)
        begin
          return JSON.parse(value[Krikri::NATIVE_TYPED_PREFIX.size..])
        rescue JSON::ParseException
          # fall through to the legacy coercion
        end
      end
      case value
      when "true", "True", "yes"
        JSON::Any.new(true)
      when "false", "False", "no"
        JSON::Any.new(false)
      else
        if leading_zero_number?(value)
          JSON::Any.new(value)
        elsif value.matches?(/\A[0-7]{3,4}\z/)
          # Same class of bug, one zero shorter: an octal-MODE-shaped
          # string with no leading zero ("1777" - os_hardening's own
          # /dev/shm, /tmp and /var/tmp entries are exactly this shape)
          # decimal-coerced into the int 1777. Real Ansible's native
          # typing keeps a string-sourced fact a string, and the string
          # is what downstream mode:/consumers need - a fed-back int
          # instead re-triggers the executor's int-mode reformatting
          # (`'%04o'`, see substitute_task_params's key == "mode"
          # comment), turning "1777" into "3361" and corrupting real
          # directory permissions again. The executor's reformat can
          # afford to be unconditional (and must be - geerlingguy.redis's
          # `mode: "{{ redis_conf_mode }}"` with 0640's decimal 416 was
          # misapplied as octal 416, never converging against
          # redis-server's own postinst chmod 640) precisely because this
          # coercion no longer manufactures fake ints out of octal-shaped
          # strings. Numeric comparisons are unaffected either way -
          # compare_values parses both sides numerically.
          JSON::Any.new(value)
        elsif int_value = value.to_i64?
          JSON::Any.new(int_value)
        elsif float_value = value.to_f64?
          JSON::Any.new(float_value)
        elsif (value.starts_with?('{') || value.starts_with?('[')) && (parsed = try_parse_json(value))
          parsed
        else
          JSON::Any.new(value)
        end
      end
    end

    # Native containers (a whole-value `{{ some_list }}`/`{{ some_dict }}`
    # set_fact) arrive here as the JSON text VariableLookup#format_value
    # serialized them to - parse that back to a real Hash/Array so later
    # dotted access (`os_shadow_perms.owner`) works, instead of leaving it
    # a flat string that renders "undefined".
    #
    # ONLY valid JSON, though - never a Python-repr repair pass. A value
    # that merely LOOKS like a container must stay a string: real
    # ansible-core's native typing requires the template's whole parsed
    # AST to be exactly one output node wrapping one expression, so a
    # `{% if %}...{% else %}['dummy']{% endif %}` block (or a plain quoted
    # `"['a']"` literal) renders to a plain str and set_fact stores it as
    # a string, period. Found live vs real ansible-playbook via
    # HanXHX.debian_bootstrap: its `dbs_repo_old` block-tag default whose
    # output text happens to be `['dummy']` became a real ARRAY here, so
    # a later `loop: "{{ dbs_repo_old }}"` silently iterated where real
    # Ansible hard-fails with "The `loop` value must resolve to a 'list',
    # not 'str'.". A genuine container never reaches this branch as
    # single-quoted repr text - the evaluator serializes containers to
    # double-quoted JSON before the plugin ever sees them.
    private def try_parse_json(value : String) : JSON::Any?
      JSON.parse(value)
    rescue JSON::ParseException
      nil
    end

    private def leading_zero_number?(value : String) : Bool
      value.size > 1 && value[0] == '0' && value[1].ascii_number?
    end
  end
end
