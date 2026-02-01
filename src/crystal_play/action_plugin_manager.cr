require "json"
require "./base_action_plugin"
require "./template_action_plugin"

module CrystalPlay
  # Action Plugin Manager
  # Detects which plugins have action components and runs them on the controller
  # before delegating to the regular plugin on the remote
  
  class ActionPluginManager
    # Map of module names to their action plugin classes
    ACTION_PLUGINS = {
      "ansible.builtin.template" => TemplateActionPlugin,
      "template" => TemplateActionPlugin,
    }
    
    # Check if a module has an action plugin
    def self.has_action_plugin?(module_name : String) : Bool
      ACTION_PLUGINS.has_key?(module_name)
    end
    
    # Execute action plugin on controller
    # Returns ActionResult with modified params or error
    def self.execute_action(
      module_name : String,
      params : Hash(String, String),
      vars : Hash(String, JSON::Any),
      host : Host
    ) : ActionResult
      
      # Get action plugin class
      plugin_class = ACTION_PLUGINS[module_name]?
      unless plugin_class
        # No action plugin for this module - pass through
        return ActionResult.pass_through
      end
      
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
