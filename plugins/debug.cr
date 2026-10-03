#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/variable_substitutor/variable_lookup"

module Krikri
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
      # Get msg or var parameter
      msg = @params["msg"]?
      var_name = @params["var"]?

      # msg and var are mutually exclusive in real ansible.builtin.debug -
      # the action plugin fails the task with exactly this message before
      # the verbosity gate or any output happens.
      if msg && var_name
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "'msg' and 'var' are incompatible options"
        )
      end

      # Get verbosity level (default: 0)
      required_verbosity = @params["verbosity"]?.try(&.to_i?) || 0
      current_verbosity = @params["_verbosity"]?.try(&.to_i) || 0

      # Skip if verbosity too low - real's registered result for a
      # verbosity-skipped debug carries skipped but NO msg key at all
      # (podman-diff debug_edge_cases D3).
      if current_verbosity < required_verbosity
        return PluginResult.new(
          changed: false,
          failed: false,
          skipped: true
        )
      end

      # Neither msg nor var is not an error: real ansible.builtin.debug
      # documents `msg` as defaulting to "Hello world!" and prints that
      # (verified against ansible-core 2.19.4 - a bare `debug:` task
      # succeeds and prints it). This engine failed the task outright
      # with "msg or var parameter required", so a bare debug: - which is
      # exactly what a task relying on module_defaults for its msg looks
      # like - broke the play.
      msg = "Hello world!" if !msg && !var_name

      # Build the debug output. Real debug's var: result carries the
      # value under the VARIABLE NAME key, not under msg (podman-diff
      # debug_edge_cases D1/D4); an unresolvable var: name maps to the
      # literal string "VARIABLE IS NOT DEFINED!" and the task still
      # succeeds.
      result = PluginResult.new(
        changed: false,
        failed: false
      )
      if var_name
        debug_var(var_name, result)
        # Real's registered debug var: result runs the VARIABLE-NAME key,
        # failed, changed (live-verified vs 2.19.11 via `{{ r | to_json }}`)
        # - mirrors DebugActionPlugin's key_order.
        result.key_order = [var_name]
      else
        result.msg = msg.to_s
        # Real's registered debug msg result runs msg, failed, changed
        # (live-verified vs 2.19.11).
        result.key_order = ["msg"]
      end
      result
    end

    # Real debug's var: result carries the value under the VARIABLE NAME
    # key, not under msg (podman-diff debug_edge_cases D1/D4); an
    # unresolvable var: name maps to the literal string "VARIABLE IS NOT
    # DEFINED!" and the task still succeeds.
    private def debug_var(var_name : String, result : PluginResult) : Nil
      var_value = lookup_variable(var_name)
      unless var_value
        result.extra[var_name] = JSON::Any.new("VARIABLE IS NOT DEFINED!")
        return
      end

      # Same shape the action plugin (the copy that runs for a normal
      # debug: task) applies: real debug's var= templates the looked-up
      # value through the Templar, so a LAZY var - an author `vars:`
      # entry whose own value is an unrendered `{{ ... }}` chain - is
      # rendered here too, and a templating error fails the task.
      # Unsafe gates, shared with every other re-render site: a var
      # resolved through an execution-resolved root
      # (VarSubstitutor.unsafe_root?) or carrying the exact text of a
      # module result / fact / set_fact (UnsafeValues.unsafe_text?) is
      # AnsibleUnsafe - printed verbatim, never re-templated. The
      # registries these consult are rebuilt from the config's
      # serialized snapshot in the driver above.
      unsafe = VarSubstitutor.unsafe_root?(@vars, var_name)
      begin
        rendered = unsafe ? var_value : render_lazy_templates(var_value)
      rescue ex
        result.failed = true
        result.msg = ex.message || "templating var '#{var_name}' failed"
        return
      end
      result.extra[var_name] = rendered
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
        # as_i is Int32-only, raises "Arithmetic overflow" for a value
        # like a large uid (2147483659) - see playbook_parser.cr's own
        # identical fix for the same root cause.
        value.as_i64.to_s
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

# Rebuild this process' unsafe-name/text registries from the config's
# serialized snapshot (see build_plugin_config) BEFORE any evaluation: an
# `async:` task runs this binary in a detached process whose registries
# start empty, which would leave the hostile-data re-render gates below
# blind. No-op when the config carries no snapshot (manual invocation).
Krikri::VarSubstitutor.hydrate_unsafe_registry_from_config(config)

plugin = Krikri::DebugPlugin.new(config)
plugin.run
