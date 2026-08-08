#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/variable_substitutor/variable_lookup"

module CrystalPlay
  # Debug plugin - prints messages and variable values
  # Compatible with Ansible's ansible.builtin.debug module
  # 
  # Parameters:
  #   msg: Message to print (supports variable substitution)
  #   var: Variable name to print (prints variable name and value)
  #   verbosity: Only print if playbook verbosity >= this level (default: 0)
  #
  # Examples:
  #   debug:
  #     msg: "Hello World"
  #
  #   debug:
  #     msg: "The value is {{ myvar }}"
  #
  #   debug:
  #     var: ansible_hostname
  #
  #   debug:
  #     msg: "Debug message"
  #     verbosity: 2
  class DebugPlugin < BasePlugin
    def execute : PluginResult
      # Get verbosity level (default: 0)
      required_verbosity = @params["verbosity"]?.try(&.to_i) || 0
      current_verbosity = @params["_verbosity"]?.try(&.to_i) || 0
      
      # Skip if verbosity too low
      if current_verbosity < required_verbosity
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "skipped",
          skipped: true
        )
      end
      
      # Get msg or var parameter
      msg = @params["msg"]?
      var_name = @params["var"]?
      
      # Must have either msg or var
      if !msg && !var_name
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "msg or var parameter required"
        )
      end
      
      # Build the debug output
      debug_output = if var_name
        # Print variable name and value
        # The var_name might be a path like "result.stdout" or just "myvar"
        var_value = lookup_variable(var_name)
        
        if var_value
          # Format as readable output
          value_str = format_value(var_value)
          "#{var_name}: #{value_str}"
        else
          "#{var_name}: VARIABLE IS NOT DEFINED!"
        end
      else
        # Print message (already substituted by task executor)
        msg.to_s
      end
      
      # Debug always succeeds and never changes anything
      PluginResult.new(
        changed: false,
        failed: false,
        msg: debug_output
      )
    end
    
    # Look up a variable (supports nested paths like "result.stdout")
    # `var:` takes a bare expression, not a {{ }}-wrapped one, so it never
    # went through VarSubstitutor#substitute (which only processes text
    # containing "{{") - this used to be its own hand-rolled dotted-only
    # resolver, unable to handle indexing at all
    # (`ansible_facts.getent_passwd['user']` - dev-sec os_hardening's own
    # molecule test verifies exactly this shape). Delegates to
    # VariableLookup#resolve, the same chained dotted+indexed resolver
    # {{ }} substitution and when: conditions already use.
    private def lookup_variable(var_name : String) : JSON::Any?
      VariableSubstitutor::VariableLookup.new(@vars).resolve(var_name)
    end
    
    # Format a JSON::Any value for display
    private def format_value(value : JSON::Any) : String
      case value.raw
      when String
        value.as_s
      when Int64, Int32
        value.as_i.to_s
      when Float64
        value.as_f.to_s
      when Bool
        value.as_bool.to_s
      when Nil
        "null"
      when Array
        # For arrays, check if they're simple values or complex
        array = value.as_a
        if array.all? { |item| item.as_s? || item.as_i? || item.as_bool? }
          # Simple array - format as list
          "[" + array.map { |item| format_value(item) }.join(", ") + "]"
        else
          # Complex array - use JSON
          value.to_pretty_json
        end
      when Hash
        # Pretty print JSON for complex types
        value.to_pretty_json
      else
        value.to_s
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::DebugPlugin.new(config)
plugin.run
