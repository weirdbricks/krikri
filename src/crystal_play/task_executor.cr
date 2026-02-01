require "json"
require "colorize"
require "./playbook_parser"
require "./variable_substitutor"
require "./plugin_manager"

module CrystalPlay
  class TaskExecutor
    property hosts : Array(CrystalPlay::Host)
    property tasks : Array(CrystalPlay::Task)
    property handlers : Array(CrystalPlay::Task)
    property check_mode : Bool
    property diff_mode : Bool
    property play_vars : Hash(String, String)
    
    # Track results for recap
    @results : Hash(String, Hash(String, Int32))
    # Track registered variables per host
    @registered_vars : Hash(String, Hash(String, JSON::Any))
    # Track notified handlers (per host)
    @notified_handlers : Hash(String, Set(String))
    
    def initialize(@hosts, @tasks, @handlers = [] of CrystalPlay::Task, @check_mode = false, @diff_mode = false, @play_vars = {} of String => String)
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      @notified_handlers = Hash(String, Set(String)).new
      
      @hosts.each do |host|
        @results[host.name] = {
          "ok" => 0,
          "changed" => 0,
          "failed" => 0
        }
        @registered_vars[host.name] = {} of String => JSON::Any
        @notified_handlers[host.name] = Set(String).new
      end
    end
    
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
    
    def show_recap
      @hosts.each do |host|
        stats = @results[host.name]
        
        status_parts = [] of String
        
        # OK count (green)
        status_parts << "ok=#{stats["ok"]}".colorize(:green).to_s
        
        # Changed count (yellow if any)
        if stats["changed"] > 0
          status_parts << "changed=#{stats["changed"]}".colorize(:yellow).to_s
        else
          status_parts << "changed=#{stats["changed"]}".colorize(:green).to_s
        end
        
        # Failed count (red if any)
        if stats["failed"] > 0
          status_parts << "failed=#{stats["failed"]}".colorize(:red).to_s
        else
          status_parts << "failed=#{stats["failed"]}".colorize(:green).to_s
        end
        
        puts "#{host.name.ljust(20)} : #{status_parts.join("  ")}"
      end
    end
  
    private def execute_task(task : CrystalPlay::Task, host : CrystalPlay::Host)
      # Build variable context
      vars_context = build_variable_context(host, task)
      
      # Create variable substitutor
      substitutor = CrystalPlay::VariableSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in task parameters
      substituted_params = substitute_task_params(task.params, substitutor)
      
      # Build config for plugin
      config = build_plugin_config_with_params(task, host, substituted_params)
      
      # Get plugin path (for debug output if needed)
      plugin_path = get_plugin_path(task.module_name)
      
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
            notify_handler(host, handler_name)
          end
        end
      end
      
      # Display result
      display_result(host, result)
      
      # Update stats
      update_stats(host, result)
    end
    
    # Build variable context combining play vars, host vars, and registered vars
    private def build_variable_context(host : CrystalPlay::Host, task : CrystalPlay::Task) : Hash(String, JSON::Any)
      context = Hash(String, JSON::Any).new
      
      # Add play-level variables (these are strings, need to wrap)
      @play_vars.each do |key, value|
        context[key] = JSON::Any.new(value)
      end
      
      # Add host variables (already JSON::Any, just assign)
      host.vars.each do |key, value|
        context[key] = value
      end
      
      # Add task-level variables (already JSON::Any, just assign)
      task.vars.each do |key, value|
        context[key] = value
      end
      
      # Add registered variables for this host (already JSON::Any)
      @registered_vars[host.name].each do |key, value|
        context[key] = value
      end
      
      context
    end
    
    # Substitute variables in task parameters
    private def substitute_task_params(params : Hash(String, String), substitutor : CrystalPlay::VariableSubstitutor) : Hash(String, String)
      result = Hash(String, String).new
      
      params.each do |key, value|
        result[key] = substitutor.substitute(value)
      end
      
      result
    end
    
    # Register task result as a variable
    private def register_result(host : CrystalPlay::Host, register_name : String, result : JSON::Any)
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
    
    private def build_plugin_config(task : CrystalPlay::Task, host : CrystalPlay::Host) : String
      # Build variable context
      vars_context = build_variable_context(host, task)
      
      # Create variable substitutor
      substitutor = CrystalPlay::VariableSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in task parameters
      substituted_params = substitute_task_params(task.params, substitutor)
      
      build_plugin_config_with_params(task, host, substituted_params)
    end
    
    private def build_plugin_config_with_params(task : CrystalPlay::Task, host : CrystalPlay::Host, params : Hash(String, String)) : String
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
        "vars" => host.vars
      }
      
      config.to_json
    end
    
    private def get_plugin_path(module_name : String) : String
      # Strip FQCN to get simple plugin filename
      # ansible.builtin.copy → copy
      # ansible.legacy.command → command
      plugin_name = module_name.sub(/^ansible\.(builtin|legacy)\./, "")
  
      # Try compiled plugin first
      compiled = "./bin/plugins/#{plugin_name}"
      return compiled if File.exists?(compiled)
  
      # Try source file
      source = "./plugins/#{plugin_name}.cr"
      return source if File.exists?(source)
  
      # Not found
      raise "Plugin not found: #{module_name} (looked for #{plugin_name})"
    end

    private def display_result(host : CrystalPlay::Host, result : JSON::Any)
      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      msg = result["msg"]?.try(&.as_s) || ""
      
      # Status indicator
      status = if failed
        "failed".colorize(:red).bold
      elsif changed
        "changed".colorize(:yellow)
      else
        "ok".colorize(:green)
      end
      
      puts "#{status}: [#{host.name}]"
      
      # Display diff if present and diff_mode enabled
      if @diff_mode && result["diff"]?
        display_diff(result["diff"])
      end
    end
    
    private def display_diff(diff : JSON::Any)
      puts ""
      
      # Content diff (copy, template)
      if diff["before"]? && diff["after"]? && diff["before"].as_s? && diff["after"].as_s?
        display_content_diff(diff)
      # Attribute diff (file)
      elsif diff["before"]?.try(&.as_h?) && diff["after"]?.try(&.as_h?)
        display_attribute_diff(diff)
      end
    end
    
    private def display_content_diff(diff : JSON::Any)
      before = diff["before"].as_s
      after = diff["after"].as_s
      before_header = diff["before_header"]?.try(&.as_s) || "before"
      after_header = diff["after_header"]?.try(&.as_s) || "after"
      
      puts "--- #{before_header}".colorize(:red).bold
      puts "+++ #{after_header}".colorize(:green).bold
      
      show_unified_diff(before, after)
      puts ""
    end
    
    private def display_attribute_diff(diff : JSON::Any)
      before = diff["before"].as_h
      after = diff["after"].as_h
      
      puts "--- before".colorize(:red).bold
      puts "+++ after".colorize(:green).bold
      
      # Show changes
      all_keys = (before.keys + after.keys).uniq.sort
      all_keys.each do |key|
        before_val = before[key]?
        after_val = after[key]?
        
        if before_val && after_val && before_val.to_s != after_val.to_s
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        elsif before_val && !after_val
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
        elsif after_val && !before_val
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        end
      end
      puts ""
    end
    
    private def show_unified_diff(before : String, after : String)
      # Create temp files for diff
      before_file = "/tmp/crystal-play-before-#{Random::Secure.hex(4)}"
      after_file = "/tmp/crystal-play-after-#{Random::Secure.hex(4)}"
      
      File.write(before_file, before)
      File.write(after_file, after)
      
      # Run diff command
      diff_output = `diff -u #{before_file} #{after_file} 2>/dev/null`
      
      # Cleanup
      File.delete(before_file) if File.exists?(before_file)
      File.delete(after_file) if File.exists?(after_file)
      
      # Skip first two lines (--- and +++ headers, we show our own)
      lines = diff_output.lines
      return if lines.size < 3
      
      # Colorize and display
      lines[2..-1].each do |line|
        colored = case line[0]?
        when '-'
          line.colorize(:red)
        when '+'
          line.colorize(:green)
        when '@'
          line.colorize(:cyan).bold
        else
          line
        end
        puts colored
      end
    end
    
    private def update_stats(host : CrystalPlay::Host, result : JSON::Any)
      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      
      stats = @results[host.name]
      
      if failed
        stats["failed"] += 1
      elsif changed
        stats["changed"] += 1
      else
        stats["ok"] += 1
      end
    end
    
    # Notify a handler (by name or listen topic)
    private def notify_handler(host : CrystalPlay::Host, handler_name : String)
      @notified_handlers[host.name].add(handler_name)
    end
    
    # Run all notified handlers at the end of the play
    private def run_handlers
      # Check if any handlers were notified
      total_notified = @notified_handlers.values.sum(&.size)
      return if total_notified == 0
      
      puts "RUNNING HANDLER".colorize(:white).bold
      puts "*" * 70
      
      # Handlers run in the order they are defined, not the order they were notified
      # For each handler, check if it was notified for any host
      @handlers.each do |handler|
        handler_triggered = false
        
        @hosts.each do |host|
          # Check if handler was notified by name or by listen topic
          should_run = false
          
          # Check by handler name
          if @notified_handlers[host.name].includes?(handler.name)
            should_run = true
          end
          
          # Check by listen topic
          if handler.listen && @notified_handlers[host.name].includes?(handler.listen)
            should_run = true
          end
          
          if should_run
            unless handler_triggered
              puts "HANDLER [#{handler.name}]".colorize(:cyan).bold
              handler_triggered = true
            end
            
            execute_handler(handler, host)
          end
        end
        
        puts "" if handler_triggered
      end
    end
    
    # Execute a single handler (just like a task)
    private def execute_handler(handler : CrystalPlay::Task, host : CrystalPlay::Host)
      # Build variable context
      vars_context = build_variable_context(host, handler)
      
      # Create variable substitutor
      substitutor = CrystalPlay::VariableSubstitutor.new(
        vars: vars_context,
        host_name: host.name
      )
      
      # Substitute variables in handler parameters
      substituted_params = substitute_task_params(handler.params, substitutor)
      
      # Build config for plugin
      config = build_plugin_config_with_params(handler, host, substituted_params)
      
      # Get plugin path
      plugin_path = get_plugin_path(handler.module_name)
      
      # Execute plugin using PluginManager
      config_json = JSON.parse(config)
      
      # Build variable context for handler
      handler_vars_context = build_variable_context(host, handler)
      
      result = PluginManager.execute_plugin(
        handler.module_name,
        config_json,
        host,
        handler_vars_context
      )
      
      # Display result
      display_result(host, result)
      
      # Update stats (handlers count as tasks)
      update_stats(host, result)
    end
  end
end
