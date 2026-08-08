#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # set_fact plugin - sets arbitrary variables for subsequent tasks on the
  # same host (ansible.builtin.set_fact). Never touches the filesystem or
  # network and never reports changed, so it's safe under --check.
  #
  # Unlike most plugins here, set_fact needs no action-plugin machinery: it
  # simply echoes its own (already-substituted) params back as
  # `ansible_facts`, the same generic result field the "facts" plugin
  # already returns from gather_facts - TaskExecutor merges any task
  # result's `ansible_facts` into that host's fact store, so set_fact just
  # needs to be a plain module that returns one.
  class SetFactPlugin < BasePlugin
    # set_fact's own control parameter, not a fact to set. `cacheable:`
    # (persisting into a fact cache plugin) has no cache backend to persist
    # into here, so it's accepted and ignored rather than turned into a
    # literal `cacheable` fact.
    CONTROL_PARAMS = {"cacheable"}

    def execute : PluginResult
      facts = Hash(String, JSON::Any).new

      @params.each do |key, value|
        next if CONTROL_PARAMS.includes?(key)
        facts[key] = coerce(value)
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "ok",
        ansible_facts: JSON::Any.new(facts)
      )
    end

    # Best-effort scalar type coercion. Params arrive here as plain
    # substituted strings (TaskExecutor substitutes every task param to a
    # String before handing it to a plugin), so a fact set from a bool/int/
    # float-looking template result needs to be coerced back to that type
    # rather than staying a string - matching how a subsequent when:/{{ }}
    # comparison would expect it to behave.
    private def coerce(value : String) : JSON::Any
      case value
      when "true", "True", "yes"
        JSON::Any.new(true)
      when "false", "False", "no"
        JSON::Any.new(false)
      else
        if int_value = value.to_i64?
          JSON::Any.new(int_value)
        elsif float_value = value.to_f64?
          JSON::Any.new(float_value)
        elsif (value.starts_with?('{') || value.starts_with?('[')) && (parsed = try_parse_json(value))
          # A dict/list-valued fact (e.g. dynamic `set_fact: "{{
          # item.key }}": "{{ item.value }}"` over a dict item, as
          # dev-sec os_hardening's os_shadow_perms/os_passwd_perms are
          # built) arrives here as the JSON text VariableLookup#format_value
          # serialized it to - parse it back to a real Hash/Array so
          # later dotted access (`os_shadow_perms.owner`) works, instead
          # of leaving it a flat string that renders "undefined".
          parsed
        else
          JSON::Any.new(value)
        end
      end
    end

    private def try_parse_json(value : String) : JSON::Any?
      JSON.parse(value)
    rescue JSON::ParseException
      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::SetFactPlugin.new(config)
plugin.run
