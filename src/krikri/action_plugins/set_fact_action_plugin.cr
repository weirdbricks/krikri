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
      ActionResult.final(ActionResult.plugin_result_json(false, false, "ok", extra))
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

    private def try_parse_json(value : String) : JSON::Any?
      JSON.parse(value)
    rescue JSON::ParseException
      JSON.parse(value.gsub('\'', '"')) rescue nil
    end

    private def leading_zero_number?(value : String) : Bool
      value.size > 1 && value[0] == '0' && value[1].ascii_number?
    end
  end
end
