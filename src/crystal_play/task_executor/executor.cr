require "json"
require "colorize"
require "../playbook_parser"
require "../variable_substitutor"
require "../plugin_manager"
require "../conditional_evaluator"
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
    property gather_facts : Bool
    
    # Track results for recap
    getter results : Hash(String, Hash(String, Int32))
    # Track registered variables per host
    @registered_vars : Hash(String, Hash(String, JSON::Any))
    # Handler runner
    @handler_runner : HandlerRunner
    # Facts per host
    @facts : Hash(String, Hash(String, JSON::Any))
    # Hosts that hit a failed task without ignore_errors: further tasks in
    # the play are skipped for them (Ansible's default "a failure aborts
    # the rest of the play for that host" behavior).
    @halted_hosts : Set(String)

    def initialize(
      @hosts,
      @tasks,
      @handlers = [] of Task,
      @check_mode = false,
      @diff_mode = false,
      @play_vars = {} of String => JSON::Any,
      @gather_facts = true
    )
      @results = Hash(String, Hash(String, Int32)).new
      @registered_vars = Hash(String, Hash(String, JSON::Any)).new
      @facts = Hash(String, Hash(String, JSON::Any)).new
      @halted_hosts = Set(String).new
      
      @hosts.each do |host|
        @results[host.name] = {
          "ok"      => 0,
          "changed" => 0,
          "failed"  => 0,
          "skipped" => 0,
          "rescued" => 0,
        }
        @registered_vars[host.name] = {} of String => JSON::Any
        @facts[host.name] = {} of String => JSON::Any
      end
      
      # Initialize handler runner
      @handler_runner = HandlerRunner.new(@handlers, @hosts)
    end
    
    # Main execution loop
    def run
      # Gather facts if enabled
      if @gather_facts
        gather_facts_for_all_hosts
      end
      
      @tasks.each do |task|
        puts "TASK [#{task.name}]".colorize(:white).bold
        puts "*" * 70

        @hosts.each do |host|
          next if @halted_hosts.includes?(host.name)
          execute_task(task, host)
        end

        puts ""
      end
      
      # Run handlers at the end of all tasks (Ansible behavior)
      run_handlers
    end
    
    # Gather facts for all hosts using the facts plugin
    private def gather_facts_for_all_hosts
      puts "TASK [Gathering Facts]".colorize(:white).bold
      puts "*" * 70
      
      @hosts.each do |host|
        begin
          # Build minimal config for facts plugin
          vars_context = Hash(String, JSON::Any).new
          
          # Add host vars to context
          host.vars.each do |key, value|
            vars_context[key] = value
          end
          
          config = {
            "host" => {
              "name" => host.name,
              "user" => host.user,
              "port" => host.port
            },
            "params" => {} of String => String,
            "vars" => vars_context
          }
          
          config_json = JSON.parse(config.to_json)
          
          # Execute facts plugin (will be uploaded and run like other plugins)
          result = PluginManager.execute_plugin(
            "facts",
            config_json,
            host,
            vars_context
          )
          
          # Check for errors
          if result["failed"]?.try(&.as_bool)
            error_msg = result["msg"]?.try(&.as_s) || "Unknown error"
            raise "Facts gathering failed: #{error_msg}"
          end
          
          # Extract facts from result
          if ansible_facts = result["ansible_facts"]?
            facts = Hash(String, JSON::Any).new
            ansible_facts.as_h.each do |key, value|
              facts[key] = value
            end
            @facts[host.name] = facts
          end
          
          # Show success
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "ok: [#{connection_host}]".colorize(:green)
          
          # Update stats
          @results[host.name]["ok"] += 1
        rescue ex
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "failed: [#{connection_host}]".colorize(:red)
          puts "  Error gathering facts: #{ex.message}".colorize(:red)
          @results[host.name]["failed"] += 1
        end
      end
      
      puts ""
    end
    
    # Show execution recap
    def show_recap
      ResultDisplay.show_recap(@hosts, @results)
    end
    
    # Execute a task on a host - dispatches to the loop, retry, or plain
    # single-execution path depending on what the task declares.
    private def execute_task(task : Task, host : Host)
      return execute_block(task, host) if task.block?

      vars_context = build_vars_context(task, host)

      # with_fileglob needs a substitutor (for {{ vars }} in the pattern) and
      # the filesystem, so it can only be resolved here, not at parse time.
      loop_items = task.loop_items || resolve_fileglob(task, host, vars_context)

      if loop_items
        execute_looped_task(task, host, vars_context, loop_items)
        return
      end

      if (until_condition = task.until_condition) && !@check_mode
        execute_task_with_retries(task, host, vars_context, until_condition)
        return
      end

      result = execute_task_once(task, host, vars_context)
      return unless result

      finish_single_task(task, host, result)
    end

    # Build the base variable context (play/host/registered/task vars + facts)
    # shared by every execution path for a task.
    private def build_vars_context(task : Task, host : Host) : Hash(String, JSON::Any)
      vars_context = VariableContext.build(
        @play_vars,
        host,
        task,
        @registered_vars[host.name]
      )

      @facts[host.name].each do |key, value|
        vars_context[key] = value
      end

      vars_context
    end

    # Resolve with_fileglob patterns (if any) against the control host's
    # filesystem, after substituting any {{ vars }} in the pattern.
    private def resolve_fileglob(task : Task, host : Host, vars_context : Hash(String, JSON::Any)) : Array(JSON::Any)?
      patterns = task.loop_fileglob
      return nil unless patterns

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      matches = [] of String

      patterns.each do |pattern|
        substituted = substitutor.substitute(pattern)
        matches.concat(Dir.glob(substituted))
      end

      matches.sort!
      matches.map { |path| JSON::Any.new(path) }
    end

    # Run one attempt of a task (when: check + param substitution + action
    # plugin + module execution). Returns nil if the when: condition skipped
    # it (the skipped counter is already updated in that case).
    private def execute_task_once(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      item_label : String? = nil
    ) : JSON::Any?
      if when_condition = task.when_condition
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          suffix = item_label ? " => (item=#{item_label})" : ""
          puts "skipping: [#{connection_host}]#{suffix}".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return nil
        end
      end

      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
      substituted_params = substitute_task_params(task.params, substitutor)

      if ActionPluginManager.has_action_plugin?(task.module_name)
        action_result = ActionPluginManager.execute_action(
          task.module_name,
          substituted_params,
          vars_context,
          host
        )

        unless action_result.success
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => action_result.error_message || "Action plugin failed",
          }.to_json)
        end

        if modified_params = action_result.modified_params
          substituted_params = modified_params
        end
      end

      config = build_plugin_config(task, host, substituted_params, vars_context)
      config_json = JSON.parse(config)

      PluginManager.execute_plugin(
        task.module_name,
        config_json,
        host,
        vars_context
      )
    end

    # Register / notify / display / update stats for a (non-looped) task result.
    private def finish_single_task(task : Task, host : Host, result : JSON::Any)
      if register_name = task.register
        register_result(host, register_name, result) unless register_name.empty?
      end

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      ResultDisplay.display_result(host, result, @diff_mode)
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors)
      halt_if_failed(task, host, failed)
    end

    # Marks `host` as halted (no further tasks in this play run for it)
    # when `failed` and the task didn't opt out via ignore_errors:.
    private def halt_if_failed(task : Task, host : Host, failed : Bool)
      @halted_hosts.add(host.name) if failed && !task.ignore_errors
    end

    # Execute a task once per loop item, aggregating the per-item results
    # into a single registered variable (`{"changed": .., "results": [...]}`),
    # matching Ansible's shape for looped, registered tasks.
    private def execute_looped_task(
      task : Task,
      host : Host,
      base_vars_context : Hash(String, JSON::Any),
      loop_items : Array(JSON::Any)
    )
      results = [] of JSON::Any
      any_changed = false
      any_failed = false

      loop_items.each do |item|
        vars_context = base_vars_context.dup
        vars_context["item"] = item

        result = execute_task_once(task, host, vars_context, item_label: item_display(item))
        next unless result

        changed = result["changed"]?.try(&.as_bool) || false
        failed = result["failed"]?.try(&.as_bool) || false
        any_changed ||= changed
        any_failed ||= failed

        ResultDisplay.display_result(host, result, @diff_mode, item_label: item_display(item))
        ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors)

        result_hash = JSON.parse(result.to_json).as_h
        result_hash["item"] = item
        results << JSON::Any.new(result_hash)
      end

      if any_changed && (notify_list = task.notify)
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      if register_name = task.register
        unless register_name.empty?
          aggregate = {
            "changed" => JSON::Any.new(any_changed),
            "failed"  => JSON::Any.new(any_failed),
            "results" => JSON::Any.new(results),
          }
          @registered_vars[host.name][register_name] = JSON::Any.new(aggregate)
        end
      end

      halt_if_failed(task, host, any_failed)
    end

    # Render a loop item for display purposes (Ansible shows `(item=...)`).
    private def item_display(item : JSON::Any) : String
      item.raw.is_a?(String) ? item.as_s : item.to_json
    end

    # Run a task repeatedly (up to task.retries times, sleeping task.delay
    # seconds between attempts) until task.until_condition evaluates true
    # against the registered result, matching Ansible's until:/retries:/delay:.
    # Skipped entirely in check mode: most modules refuse to act in check
    # mode anyway, which would otherwise turn every retry loop into a slow,
    # guaranteed-to-fail wait for no reason.
    private def execute_task_with_retries(
      task : Task,
      host : Host,
      vars_context : Hash(String, JSON::Any),
      until_condition : String
    )
      register_name = task.register
      attempts = task.retries.clamp(1..)
      result = nil

      attempts.times do |attempt|
        result = execute_task_once(task, host, vars_context)
        break unless result

        if register_name && !register_name.empty?
          register_result(host, register_name, result)
          vars_context[register_name] = @registered_vars[host.name][register_name]
        end

        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(until_condition)
        break if ConditionalEvaluator.evaluate(substituted_condition, vars_context)

        sleep(task.delay.seconds) if attempt < attempts - 1
      end

      return unless result

      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      if changed && (notify_list = task.notify)
        notify_list.each { |handler_name| @handler_runner.notify(host, handler_name) } unless notify_list.empty?
      end

      ResultDisplay.display_result(host, result, @diff_mode)
      ResultDisplay.update_stats(@results[host.name], result, task.ignore_errors)
      halt_if_failed(task, host, failed)
    end

    # Runs a block: task - the nested block_tasks, then rescue_tasks if the
    # block failed (recovering it if rescue succeeds), then always_tasks
    # unconditionally, re-applying the halt afterward if the block ultimately
    # failed (unrescued, or rescue itself failed, or always: introduced a new
    # failure) unless the block itself has ignore_errors:.
    private def execute_block(task : Task, host : Host)
      if when_condition = task.when_condition
        vars_context = build_vars_context(task, host)
        substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)
        substituted_condition = substitutor.substitute(when_condition)

        unless ConditionalEvaluator.evaluate(substituted_condition, vars_context)
          connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
          puts "skipping: [#{connection_host}] (block)".colorize(:cyan)
          @results[host.name]["skipped"] += 1
          return
        end
      end

      failed_before = @results[host.name]["failed"]
      run_task_list(task.block_tasks || [] of Task, host)
      block_failed = @halted_hosts.includes?(host.name)

      if block_failed && (rescue_tasks = task.rescue_tasks)
        @halted_hosts.delete(host.name)
        run_task_list(rescue_tasks, host)
        block_failed = @halted_hosts.includes?(host.name)

        # rescue: succeeded - the block-body failures it recovered from
        # don't count as play failures. Move them into "rescued" instead,
        # matching Ansible's recap (failed=0 ... rescued=1).
        unless block_failed
          recovered = @results[host.name]["failed"] - failed_before
          if recovered > 0
            @results[host.name]["failed"] -= recovered
            @results[host.name]["rescued"] += recovered
          end
        end
      end

      if always_tasks = task.always_tasks
        @halted_hosts.delete(host.name)
        run_task_list(always_tasks, host)
        block_failed ||= @halted_hosts.includes?(host.name)
      end

      @halted_hosts.delete(host.name)
      halt_if_failed(task, host, block_failed)
    end

    # Runs a nested task list (block:/rescue:/always:), printing its own
    # TASK header per task since these live inside a block rather than the
    # play's top-level task list, so `run` never prints one for them. Stops
    # early once the host halts (a task failed without ignore_errors).
    private def run_task_list(tasks : Array(Task), host : Host)
      tasks.each do |nested_task|
        break if @halted_hosts.includes?(host.name)
        puts "TASK [#{nested_task.name}]".colorize(:white).bold
        puts "*" * 70
        execute_task(nested_task, host)
        puts ""
      end
    end

    # Substitute variables in task parameters
    private def substitute_task_params(
      params : Hash(String, String),
      substitutor : VarSubstitutor
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
      # Create a mutable copy of the result to add stdout_lines/stderr_lines
      result_hash = JSON.parse(result.to_json).as_h
      
      # Add stdout_lines by splitting stdout on newlines (Ansible behavior)
      if stdout = result_hash["stdout"]?.try(&.as_s)
        stdout_lines = stdout.split("\n").map { |line| JSON::Any.new(line) }
        result_hash["stdout_lines"] = JSON::Any.new(stdout_lines)
      end
      
      # Add stderr_lines by splitting stderr on newlines (Ansible behavior)
      if stderr = result_hash["stderr"]?.try(&.as_s)
        stderr_lines = stderr.split("\n").map { |line| JSON::Any.new(line) }
        result_hash["stderr_lines"] = JSON::Any.new(stderr_lines)
      end
      
      # Store the enhanced result
      @registered_vars[host.name][register_name] = JSON::Any.new(result_hash)
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
      
      # Add facts to context
      @facts[host.name].each do |key, value|
        vars_context[key] = value
      end
      
      # FIXED: Use VarSubstitutor instead of VariableSubstitutor
      substitutor = VarSubstitutor.new(
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
