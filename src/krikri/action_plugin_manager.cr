require "json"
require "./base_action_plugin"
require "./template_action_plugin"
require "./action_plugins/debug_action_plugin"
require "./action_plugins/assert_action_plugin"
require "./action_plugins/fail_action_plugin"
require "./action_plugins/set_fact_action_plugin"
require "./action_plugins/pause_action_plugin"

module Krikri
  # Action Plugin Manager
  # Detects which plugins have action components and runs them on the controller
  # before delegating to the regular plugin on the remote

  class ActionPluginManager
    # Map of module names to their action plugin classes
    ACTION_PLUGINS = {
      "ansible.builtin.template" => TemplateActionPlugin,
      "template"                 => TemplateActionPlugin,
      # These 5 return an ActionResult.final (see base_action_plugin.cr)
      # instead of modified_params - the caller never invokes a module
      # (local or remote) afterward at all. Real ansible-core's own
      # debug/assert/fail/set_fact/pause have always been action-plugin
      # only (no target-side module) - this closes that architectural
      # gap while also removing an SSH round trip + upload per task for
      # remote hosts. See each action_plugins/*_action_plugin.cr for the
      # per-module rationale.
      "ansible.builtin.debug"    => DebugActionPlugin,
      "debug"                    => DebugActionPlugin,
      "ansible.builtin.assert"   => AssertActionPlugin,
      "assert"                   => AssertActionPlugin,
      "ansible.builtin.fail"     => FailActionPlugin,
      "fail"                     => FailActionPlugin,
      "ansible.builtin.set_fact" => SetFactActionPlugin,
      "set_fact"                 => SetFactActionPlugin,
      "ansible.builtin.pause"    => PauseActionPlugin,
      "pause"                    => PauseActionPlugin,
    }

    # Check if a module has an action plugin
    def self.has_action_plugin?(module_name : String) : Bool
      ACTION_PLUGINS.has_key?(module_name)
    end

    # Modules whose action plugin ALWAYS returns ActionResult.final - no
    # module ever runs afterward, local or remote (unlike template:,
    # whose action plugin only rewrites params before a real module still
    # executes to actually write the file). PluginManager's own
    # pre-upload pass (collect_required_plugins) uses this to skip
    # putting these 5 in a remote host's upload set entirely - nothing
    # in the normal execution path ever calls get_local_plugin_path for
    # them, so uploading them was pure waste. Kept as a fixed set rather
    # than derived from ACTION_PLUGINS, since template: is a real
    # counter-example living in the same map.
    CONTROLLER_ONLY_MODULES = Set{
      "ansible.builtin.debug", "debug",
      "ansible.builtin.assert", "assert",
      "ansible.builtin.fail", "fail",
      "ansible.builtin.set_fact", "set_fact",
      "ansible.builtin.pause", "pause",
    }

    def self.skips_module_dispatch?(module_name : String) : Bool
      CONTROLLER_ONLY_MODULES.includes?(module_name)
    end

    # Execute action plugin on controller
    # Returns ActionResult with modified params or error
    def self.execute_action(
      module_name : String,
      params : Hash(String, String),
      vars : Hash(String, JSON::Any),
      host : Host,
    ) : ActionResult
      # Get action plugin class
      plugin_class = ACTION_PLUGINS[module_name]?
      unless plugin_class
        # No action plugin for this module - pass through
        return ActionResult.pass_through
      end

      # debug:'s own verbosity: gate (DebugActionPlugin) reads this back
      # out - previously never set on THIS path (only build_plugin_config's
      # remote-dispatch path set it, which the normal debug:/assert:/...
      # task-execution flow never reaches anymore now that they're
      # controller-only action plugins - see CONTROLLER_ONLY_MODULES's
      # own comment). A role's `debug: ... verbosity: N` always compared
      # against a hardcoded 0 regardless of real -v/-vv/-vvv flags.
      # Sourced from vars (ansible_verbosity, already set by the
      # executor's own build_vars_context) rather than adding a new
      # parameter to this method and every one of its 3 call sites.
      params = params.dup
      params["_verbosity"] = (vars["ansible_verbosity"]?.try(&.as_i64?) || 0_i64).to_s

      # Create and execute action plugin
      action_plugin = plugin_class.new(params, vars, host)

      # Check if should run
      unless action_plugin.should_run?
        return ActionResult.pass_through
      end

      # Execute action on controller
      action_plugin.execute
    end
  end
end
