require "json"
require "./needle_lookup"
require "./base_action_plugin"
require "./template_action_plugin"
require "./action_plugins/debug_action_plugin"
require "./action_plugins/assert_action_plugin"
require "./action_plugins/fail_action_plugin"
require "./action_plugins/set_fact_action_plugin"
require "./action_plugins/pause_action_plugin"
require "./action_plugins/synchronize_action_plugin"
require "./action_plugins/add_host_action_plugin"

module Krikri
  # Action Plugin Manager
  # Detects which plugins have action components and runs them on the controller
  # before delegating to the regular plugin on the remote

  class ActionPluginManager
    # Map of module names to their action plugin classes
    ACTION_PLUGINS = {
      "ansible.builtin.template" => TemplateActionPlugin,
      "template"                 => TemplateActionPlugin,
      # These 7 return an ActionResult.final (see base_action_plugin.cr)
      # instead of modified_params - the caller never invokes a module
      # (local or remote) afterward at all. ansible-core's own
      # debug/assert/fail/set_fact/pause/add_host have always been
      # action-plugin only (no target-side module) - this closes that
      # architectural gap while also removing an SSH round trip + upload
      # per task for remote hosts. synchronize (ansible.posix) joins them
      # with the same shape: Ansible's own synchronize runs rsync
      # from the controller/delegate, never on the target. See each
      # action_plugins/*_action_plugin.cr for the per-module rationale.
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
      "ansible.builtin.add_host" => AddHostActionPlugin,
      "add_host"                 => AddHostActionPlugin,
      # synchronize: controller-side action plugin (Ansible's own
      # synchronize runs its rsync subprocess from the controller/delegate
      # with rsync dialing out itself - see SynchronizeActionPlugin's own
      # comment) - ActionResult.final, no module dispatch afterward.
      "ansible.posix.synchronize" => SynchronizeActionPlugin,
      "synchronize"               => SynchronizeActionPlugin,
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
    # putting these 7 in a remote host's upload set entirely - nothing
    # in the normal execution path ever calls get_local_plugin_path for
    # them, so uploading them was pure waste. Kept as a fixed set rather
    # than derived from ACTION_PLUGINS, since template: is a real
    # counter-example living in the same map. Unlike the others, add_host
    # has no plugins/*.cr binary at all (there is nothing a target-side
    # add_host process could ever do), so it relies on this set.
    CONTROLLER_ONLY_MODULES = Set{
      "ansible.builtin.debug", "debug",
      "ansible.builtin.assert", "assert",
      "ansible.builtin.fail", "fail",
      "ansible.builtin.set_fact", "set_fact",
      "ansible.builtin.pause", "pause",
      "ansible.posix.synchronize", "synchronize",
      "ansible.builtin.add_host", "add_host",
    }

    def self.skips_module_dispatch?(module_name : String) : Bool
      CONTROLLER_ONLY_MODULES.includes?(module_name)
    end

    # Execute action plugin on controller
    # Returns ActionResult with modified params or error
    # `inventory` is the run's shared Inventory, passed only so plugins
    # that mutate run-scoped state (add_host:) reach the same object
    # every play's hosts:-pattern resolution reads from.
    def self.execute_action(
      module_name : String,
      params : Hash(String, String),
      vars : Hash(String, JSON::Any),
      host : Host,
      inventory : Inventory? = nil,
      task_host : Host? = nil,
      check_mode : Bool = false,
    ) : ActionResult
      # Get action plugin class
      plugin_class = ACTION_PLUGINS[module_name]?
      unless plugin_class
        # No action plugin for this module - pass through
        return ActionResult.pass_through
      end

      # The parser's non-string-literal markers (NON_STRING_PARAM_PREFIX)
      # are plugin-wire dressing: in-process action plugins that never
      # consult the native type get the demoted plain string, the same
      # contract BasePlugin's param parse gives the plugin binaries
      # (otherwise `debug: verbosity: 2` / `assert: quiet: true` /
      # `pause: minutes: 5` would read the marker-prefixed text as their
      # value). template: opts OUT - its action plugin coerces a marked
      # non-string src through Python str() itself (a bool src must be
      # searched for as "True", not "true"), so it needs the marker intact.
      # fail: opts out too - its action puts the task arg into
      # result['msg'] VERBATIM (real action/fail.py has no coercion), so a
      # marked non-string literal must reach it marked for the native type
      # to land in the wire result/fatal dump/registered var (live-verified
      # vs 2.19.11: `fail: {msg: 50}` fails with {"msg": 50}).
      # pause: opts out for the same reason, on a different param: its
      # minutes/seconds ride Ansible's int CALLABLE, under which a Python
      # bool IS an int (`seconds: true` waits 1s, `seconds: false`
      # clamps up to the same 1s minimum - both live-verified vs
      # 2.19.11) and a float truncates (int(1.9) == 1). The demoted text
      # alone makes "true" an unparseable string, so the native type has
      # to survive the trip to the plugin.
      unless module_name == "ansible.builtin.template" || module_name == "ansible.builtin.fail" || module_name == "ansible.builtin.pause"
        params = Krikri.strip_non_string_param_markers(params)
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
      # Same pattern for the task's resolved check mode - the
      # controller-only plugins never go through build_plugin_config's
      # own check_mode injection, so synchronize (whose check-mode
      # behavior IS the rsync --dry-run flag, real module's own shape)
      # reads it back from here.
      params["_ansible_check_mode"] = check_mode.to_s

      # Create and execute action plugin
      action_plugin = plugin_class.new(params, vars, host, inventory, task_host)

      # Check if should run
      unless action_plugin.should_run?
        return ActionResult.pass_through
      end

      # Execute action on controller
      action_plugin.execute
    end
  end
end
