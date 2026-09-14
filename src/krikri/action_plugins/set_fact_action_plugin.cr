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

    def execute : ActionResult
      facts = Hash(String, JSON::Any).new

      @params.each do |key, value|
        next if CONTROL_PARAMS.includes?(key)
        facts[key] = coerce(value)
      end

      extra = {"ansible_facts" => JSON::Any.new(facts)}
      ActionResult.final(ActionResult.plugin_result_json(false, false, "", extra))
    end

    private def coerce(value : String) : JSON::Any
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
