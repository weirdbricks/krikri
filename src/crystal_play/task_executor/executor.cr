require "json"
require "colorize"
require "../playbook_parser"
require "../variable_substitutor"
require "../plugin_manager"
require "./variable_context"
require "./result_display"
require "./handler_runner"
require "../action_plugin_manager"

module CrystalPlay
  # TaskExecutor - Executes tasks on hosts
  # Orchestrates task execution, variable substitution, and handler management
  class TaskExecutor
    property hosts : Array(Host)
    property tasks : Array(Task)
    property handlers : Array(Task)
    property check_mode : Bool
    property diff_mode : Bool
    property play_vars : Hash(String, JSON::Any)
    
    # Track results for recap
    @results : Hash(String, Hash(String, Int32))
    # Track registered variables per host
    @registered_vars : Hash(String, Hash(String, JSON::Any))
    # Handler runner
    @handler_runner : HandlerRunner
    
    def initialize(
      @hosts,
      @tasks,
      @handlers = [] of Task,
      @check_mode = false,
      @diff_mode = false,
      @play_vars = {} of String => String
    )
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      
      @hosts.each do |host|
        @results[host.name] = {
          "ok" => 0,
          "changed" => 0,
          "failed" => 0
        }
        @registered_vars[host.name] = {} of String => JSON::Any
      end
      
      # Initialize handler runner
      @handler_runner = HandlerRunner.new(@handlers, @hosts)
    end
    
    # Main execution loop
    def run
      @tasks.each do |task|
        puts "TASK [#{task.name}]".colorize(:white).bold
        puts "*" * 70
        
        @hosts.each do |host|
          execute_task(task, host)
        end
        
        puts ""
      end
      
      # Run handlers at the end of all tasks (Ansible behavior)
      run_handlers
    end
    
    # Show execution recap
    def show_recap
      ResultDisplay.show_recap(@hosts, @results)
    end
    
    # Execute a single task on a host
    private def execute_task(task : Task, host : Host)
      # Build variable context
      vars_context = VariableContext.build(
        @play_vars,
        host,
        task,
        @registered_vars[host.name]
      )
      
      # Create variable substitutor
      substitutor = VariableSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in task parameters
      substituted_params = substitute_task_params(task.params, substitutor)
      
            if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(
          task.module_name,
          substituted_params,
          vars_context,
          host
        )
        
        # Handle action plugin failure
        unless action_result.success
          error_result = JSON.parse({
            "changed" => false,
            "failed" => true,
            "msg" => action_result.error_message || "Action plugin failed"
          }.to_json)
          
          # Display result and update stats
          ResultDisplay.display_result(host, error_result, @diff_mode)
          ResultDisplay.update_stats(@results[host.name], error_result)
          return
        end
        
        # Use modified params from action plugin if provided
        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end
      
      # Build config for plugin
      config = build_plugin_config(task, host, substituted_params, vars_context)
      
      # Execute plugin using PluginManager (handles local vs remote)
      config_json = JSON.parse(config)
      result = PluginManager.execute_plugin(
        task.module_name,
        config_json,
        host,
        vars_context
      )
      
      # Handle register directive
      if register_name = task.register
        if !register_name.empty?
          register_result(host, register_name, result)
        end
      end
      
      # Handle notify directive (only if task changed)
      changed = result["changed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        if !notify_list.empty?
          notify_list.each do |handler_name|
            @handler_runner.notify(host, handler_name)
          end
        end
      end
      
      # Display result
      ResultDisplay.display_result(host, result, @diff_mode)
      
      # Update stats
      ResultDisplay.update_stats(@results[host.name], result)
    end
    
    # Substitute variables in task parameters
    private def substitute_task_params(
      params : Hash(String, String),
      substitutor : VariableSubstitutor
    ) : Hash(String, String)
      result = Hash(String, String).new
      
      params.each do |key, value|
        result[key] = substitutor.substitute(value)
      end
      
      result
    end
    
    # Build plugin configuration
    private def build_plugin_config(
      task : Task,
      host : Host,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any)
    ) : String
      # Add check_mode and diff_mode to params
      final_params = params.dup
      final_params["check_mode"] = @check_mode.to_s
      final_params["diff_mode"] = @diff_mode.to_s
      
      config = {
        "host" => {
          "name" => host.name,
          "user" => host.user,
          "port" => host.port
        },
        "params" => final_params,
        "vars" => vars_context
      }
      
      config.to_json
    end
    
    # Register task result as a variable
    private def register_result(host : Host, register_name : String, result : JSON::Any)
      # Store the entire result
      @registered_vars[host.name][register_name] = result
      
      # Also make common fields easily accessible
      if stdout = result["stdout"]?
        @registered_vars[host.name]["#{register_name}.stdout"] = stdout
      end
      if stderr = result["stderr"]?
        @registered_vars[host.name]["#{register_name}.stderr"] = stderr
      end
      if rc = result["rc"]?
        @registered_vars[host.name]["#{register_name}.rc"] = rc
      end
    end
    
    # Run all notified handlers
    private def run_handlers
      # Create callback for handler execution
      # This allows HandlerRunner to execute handlers without duplicating logic
      execute_callback = ->(handler : Task, host : Host) : JSON::Any {
        execute_handler_internal(handler, host)
      }
      
      @handler_runner.run(execute_callback, @results, @diff_mode)
    end
    
    # Execute a handler (internal - called via callback)
    private def execute_handler_internal(handler : Task, host : Host) : JSON::Any
      # Build variable context
      vars_context = VariableContext.build(
        @play_vars,
        host,
        handler,
        @registered_vars[host.name]
      )
      
      # Create variable substitutor
      substitutor = VariableSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in handler parameters
      substituted_params = substitute_task_params(handler.params, substitutor)
      
      # Build config for plugin
      config = build_plugin_config(handler, host, substituted_params, vars_context)
      
      # Execute plugin using PluginManager
      config_json = JSON.parse(config)
      
      PluginManager.execute_plugin(
        handler.module_name,
        config_json,
        host,
        vars_context
      )
    end
  end
end
