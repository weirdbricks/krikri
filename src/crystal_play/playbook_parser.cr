require "yaml"
require "./loop_resolver"

module CrystalPlay
  # Represents a single task in a playbook
  class Task
    property name : String
    property module_name : String
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    property when_condition : String?
    property register : String?
    property notify : Array(String)?
    property listen : String?
    property ignore_errors : Bool
    property check_mode : Bool?
    property diff_mode : Bool?
    property become : Bool
    property become_user : String?
    property tags : Array(String)
    property loop : Array(JSON::Any)?
    # Loop items already resolved at parse time (loop:, with_items:,
    # with_dict:, with_nested:, with_sequence:, with_indexed_items:).
    property loop_items : Array(JSON::Any)?
    # with_fileglob patterns, resolved at execution time (needs {{ vars }}
    # substitution and filesystem access, neither available at parse time).
    property loop_fileglob : Array(String)?
    # until: / retries: / delay: - retry a task until a condition passes.
    property until_condition : String?
    property retries : Int32
    property delay : Int32
    # block: / rescue: / always: - only set when module_name == "_block"
    # (a pseudo-module marking this Task as a block rather than a plugin
    # invocation). Blocks can nest, since these are themselves Task lists.
    property block_tasks : Array(Task)?
    property rescue_tasks : Array(Task)?
    property always_tasks : Array(Task)?

    def initialize(@name : String, @module_name : String)
      @params = Hash(String, String).new
      @vars = Hash(String, JSON::Any).new
      @when_condition = nil
      @register = nil
      @notify = nil
      @listen = nil
      @ignore_errors = false
      @check_mode = nil
      @diff_mode = nil
      @become = false
      @become_user = nil
      @tags = [] of String
      @loop = nil
      @loop_items = nil
      @loop_fileglob = nil
      @until_condition = nil
      @retries = 3
      @delay = 5
      @block_tasks = nil
      @rescue_tasks = nil
      @always_tasks = nil
    end

    def block? : Bool
      @module_name == "_block"
    end
    
    def to_s(io : IO)
      io << "Task(#{@name}, #{@module_name})"
    end
  end
  
  # Represents a play (collection of tasks for specific hosts)
  class Play
    property name : String
    property hosts : String | Array(String)
    property tasks : Array(Task)
    property vars : Hash(String, JSON::Any)
    property become : Bool
    property become_user : String?
    property gather_facts : Bool
    property tags : Array(String)
    property handlers : Array(Task)
    
    def initialize(@name : String, @hosts : String | Array(String))
      @tasks = [] of Task
      @vars = Hash(String, JSON::Any).new
      @become = false
      @become_user = nil
      @gather_facts = true
      @tags = [] of String
      @handlers = [] of Task
    end
    
    def to_s(io : IO)
      io << "Play(#{@name}, hosts: #{@hosts}, #{@tasks.size} tasks)"
    end
  end
  
  # Represents an entire playbook
  class Playbook
    property plays : Array(Play)
    property path : String
    
    def initialize(@path : String)
      @plays = [] of Play
    end
    
    def to_s(io : IO)
      io << "Playbook(#{@path}, #{@plays.size} plays)"
    end
  end
  
  # Parser for Ansible YAML playbooks
  class PlaybookParser
    
    # List of available (implemented) plugins - using FQCN. Almost all of
    # these are ansible.builtin.* (bundled with ansible-core); authorized_key
    # is the one exception - in real Ansible it lives in the separate
    # ansible.posix collection, not ansible-core, so it needs its own prefix
    # here too (verified against a real ansible-core install, not assumed).
    AVAILABLE_PLUGINS = [
      "ansible.builtin.copy",
      "ansible.builtin.template",
      "ansible.builtin.file",
      "ansible.builtin.lineinfile",
      "ansible.builtin.service",
      "ansible.builtin.shell",
      "ansible.builtin.apt",
      "ansible.builtin.dnf",
      "ansible.builtin.package",
      "ansible.builtin.debug",
      "ansible.builtin.command",
      "ansible.builtin.user",
      "ansible.builtin.group",
      "ansible.builtin.git",
      "ansible.builtin.cron",
      "ansible.posix.authorized_key",
    ]
    
    # Parse playbook from file
    def self.parse(path : String) : Playbook
      unless File.exists?(path)
        raise "Playbook file not found: #{path}"
      end
      
      content = File.read(path)
      parse_string(content, path)
    end
    
    # Parse playbook from string
    def self.parse_string(content : String, path : String = "playbook.yml") : Playbook
      playbook = Playbook.new(path)
      
      begin
        yaml = YAML.parse(content)
      rescue ex : YAML::ParseException
        raise "Invalid YAML in #{path}: #{ex.message}"
      end
      
      # Playbook is an array of plays
      unless yaml.as_a?
        raise "Playbook must be a YAML list of plays"
      end
      
      yaml.as_a.each_with_index do |play_yaml, index|
        begin
          play = parse_play(play_yaml, index)
          playbook.plays << play
        rescue ex
          puts "Warning: Failed to parse play #{index + 1}: #{ex.message}".colorize(:yellow)
        end
      end
      
      if playbook.plays.empty?
        raise "No valid plays found in playbook"
      end
      
      playbook
    end
    
    # Parse a single play
    private def self.parse_play(yaml : YAML::Any, index : Int32) : Play
      unless yaml.as_h?
        raise "Play must be a YAML mapping (hash)"
      end
      
      # Get play name
      name = yaml["name"]?.try(&.as_s) || "Play #{index + 1}"
      
      # Get hosts (required)
      hosts_yaml = yaml["hosts"]?
      unless hosts_yaml
        raise "Play '#{name}' missing required 'hosts' field"
      end
      
      hosts = if hosts_yaml.as_a?
        hosts_yaml.as_a.map(&.as_s)
      else
        hosts_yaml.as_s
      end
      
      play = Play.new(name, hosts)
      
      # Parse play-level settings
      play.become = yaml["become"]?.try(&.as_bool) || false
      play.become_user = yaml["become_user"]?.try(&.as_s)
      gather_facts_yaml = yaml["gather_facts"]?
      play.gather_facts = gather_facts_yaml ? gather_facts_yaml.as_bool : true
      
      # Parse play-level vars
      if vars_yaml = yaml["vars"]?.try(&.as_h?)
        vars_yaml.each do |key, value|
          play.vars[key.to_s] = JSON.parse(value.to_json)
        end
      end
      
      # Parse tags
      if tags_yaml = yaml["tags"]?.try(&.as_a?)
        play.tags = tags_yaml.map(&.as_s)
      end
      
      # Parse tasks
      if tasks_yaml = yaml["tasks"]?.try(&.as_a?)
        play.tasks = parse_tasks(tasks_yaml, play, "task in play '#{name}'")
      end

      # Parse handlers
      if handlers_yaml = yaml["handlers"]?.try(&.as_a?)
        play.handlers = parse_tasks(handlers_yaml, play, "handler")
      end

      play
    end

    # Parse a list of task-shaped YAML nodes, skipping (with a warning) any
    # individual entry that fails to parse rather than failing the whole
    # list. Shared by play.tasks, play.handlers, and block/rescue/always.
    private def self.parse_tasks(tasks_yaml : Array(YAML::Any), play : Play, context : String) : Array(Task)
      tasks = [] of Task

      tasks_yaml.each_with_index do |task_yaml, index|
        begin
          tasks << parse_task(task_yaml, index, play)
        rescue ex
          puts "Warning: Skipping #{context} #{index + 1}: #{ex.message}".colorize(:yellow)
        end
      end

      tasks
    end

    # Parse a single task
    private def self.parse_task(yaml : YAML::Any, index : Int32, play : Play) : Task
      unless yaml.as_h?
        raise "Task must be a YAML mapping (hash)"
      end

      task_hash = yaml.as_h

      # Get task name
      name = task_hash["name"]?.try(&.as_s) || "Task #{index + 1}"

      if block_yaml = task_hash["block"]?.try(&.as_a?)
        return parse_block_task(name, task_hash, block_yaml, play)
      end

      # Find the module (first key that's not a special keyword)
      special_keys = ["name", "when", "register", "ignore_errors", "check_mode",
                      "diff", "become", "become_user", "tags", "with_items", "loop",
                      "with_dict", "with_fileglob", "with_nested", "with_sequence",
                      "with_indexed_items", "until", "retries", "delay",
                      "notify", "changed_when", "failed_when",
                      "block", "rescue", "always"]
      
      module_name = nil
      module_params = nil
      
      task_hash.each do |key, value|
        key_str = key.to_s
        unless special_keys.includes?(key_str)
          module_name = key_str
          module_params = value
          break
        end
      end
      
      unless module_name
        raise "No module found in task '#{name}'"
      end

      # Check if plugin is available
      unless AVAILABLE_PLUGINS.includes?(module_name)
        raise "Plugin not available: #{module_name}"
      end
      
      task = Task.new(name, module_name)
      
      # Parse module parameters
      task.params = parse_module_params(module_params.not_nil!, module_name)
      
      # Parse task-level settings - FIXED to handle boolean values safely
      task.when_condition = task_hash["when"]?.try { |v| safe_yaml_to_string(v) }
      task.register = task_hash["register"]?.try { |v| safe_yaml_to_string(v) }
      task.ignore_errors = task_hash["ignore_errors"]?.try(&.as_bool) || false
      task.check_mode = task_hash["check_mode"]?.try(&.as_bool)
      task.diff_mode = task_hash["diff"]?.try(&.as_bool)
      task.become = task_hash["become"]?.try(&.as_bool) || play.become
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user
      
      # Parse notify (can be string or array)
      if notify_yaml = task_hash["notify"]?
        if notify_yaml.as_s?
          task.notify = [notify_yaml.as_s]
        elsif notify_yaml.as_a?
          task.notify = notify_yaml.as_a.map(&.as_s)
        end
      end
      
      # Parse listen (string only)
      task.listen = task_hash["listen"]?.try { |v| safe_yaml_to_string(v) }
      
      # Parse tags
      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end
      
      # Parse loop / with_* (checked in this priority order; first match wins,
      # matching how Ansible only honors one loop source per task)
      if loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop = loop_yaml.map { |item| JSON.parse(item.to_json) }
        task.loop_items = task.loop
      elsif with_items = task_hash["with_items"]?.try(&.as_a?)
        task.loop = with_items.map { |item| JSON.parse(item.to_json) }
        task.loop_items = task.loop
      elsif with_dict = task_hash["with_dict"]?.try(&.as_h?)
        hash = Hash(String, JSON::Any).new
        with_dict.each { |k, v| hash[k.to_s] = JSON.parse(v.to_json) }
        task.loop_items = LoopResolver.with_dict(hash)
      elsif with_nested = task_hash["with_nested"]?.try(&.as_a?)
        lists = with_nested.map do |entry|
          if entry.as_a?
            entry.as_a.map { |item| JSON.parse(item.to_json) }
          else
            [JSON.parse(entry.to_json)]
          end
        end
        task.loop_items = LoopResolver.with_nested(lists)
      elsif with_sequence = task_hash["with_sequence"]?
        spec = safe_yaml_to_string(with_sequence)
        task.loop_items = LoopResolver.with_sequence(spec)
      elsif with_indexed_items = task_hash["with_indexed_items"]?.try(&.as_a?)
        items = with_indexed_items.map { |item| JSON.parse(item.to_json) }
        task.loop_items = LoopResolver.with_indexed_items(items)
      elsif with_fileglob = task_hash["with_fileglob"]?
        task.loop_fileglob = if with_fileglob.as_a?
          with_fileglob.as_a.map(&.as_s)
        else
          [with_fileglob.as_s]
        end
      end

      # Parse until / retries / delay
      task.until_condition = task_hash["until"]?.try { |v| safe_yaml_to_string(v) }
      task.retries = task_hash["retries"]?.try { |v| safe_yaml_to_string(v).to_i? } || 3
      task.delay = task_hash["delay"]?.try { |v| safe_yaml_to_string(v).to_i? } || 5

      task
    end

    # Parse a block: task - block:/rescue:/always: are each an array of
    # nested tasks (which may themselves be blocks, so this recurses
    # naturally through parse_tasks -> parse_task -> parse_block_task).
    private def self.parse_block_task(name : String, task_hash : Hash(YAML::Any, YAML::Any), block_yaml : Array(YAML::Any), play : Play) : Task
      task = Task.new(name, "_block")
      task.block_tasks = parse_tasks(block_yaml, play, "task in block '#{name}'")

      if rescue_yaml = task_hash["rescue"]?.try(&.as_a?)
        task.rescue_tasks = parse_tasks(rescue_yaml, play, "task in rescue of block '#{name}'")
      end

      if always_yaml = task_hash["always"]?.try(&.as_a?)
        task.always_tasks = parse_tasks(always_yaml, play, "task in always of block '#{name}'")
      end

      # Block-level settings gate/apply to the block as a whole; each
      # nested task still evaluates its own when:/tags:/etc in addition.
      task.when_condition = task_hash["when"]?.try { |v| safe_yaml_to_string(v) }
      task.ignore_errors = task_hash["ignore_errors"]?.try(&.as_bool) || false
      task.become = task_hash["become"]?.try(&.as_bool) || play.become
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user

      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end

      task
    end

    # Parse module parameters into a hash
    private def self.parse_module_params(yaml : YAML::Any, module_name : String) : Hash(String, String)
      params = Hash(String, String).new
      
      # Handle different parameter formats
      if yaml.as_h?
        # Hash format: key-value pairs
        yaml.as_h.each do |key, value|
          params[key.to_s] = stringify_value(value)
        end
      elsif yaml.as_s?
        # String format: single argument (e.g., command: "echo hello")
        case module_name
        when "command", "shell"
          params["cmd"] = yaml.as_s
        else
          params["_raw_params"] = yaml.as_s
        end
      else
        # Other types
        params["value"] = stringify_value(yaml)
      end
      
      params
    end
    
    # Helper: Safely convert any YAML value to string
    # This handles cases where YAML values might be booleans, integers, etc.
    private def self.safe_yaml_to_string(yaml : YAML::Any) : String
      case yaml.raw
      when String
        yaml.as_s
      when Bool
        yaml.as_bool.to_s
      when Int64, Int32
        yaml.as_i.to_s
      when Float64
        yaml.as_f.to_s
      when Nil
        ""
      else
        yaml.to_s
      end
    end
    
    # Convert YAML value to string (used for module parameters)
    private def self.stringify_value(yaml : YAML::Any) : String
      case yaml.raw
      when String
        yaml.as_s
      when Int64, Int32
        yaml.as_i.to_s
      when Float64
        yaml.as_f.to_s
      when Bool
        begin
          yaml.as_bool.to_s
        rescue
          yaml.raw.to_s
        end
      when Nil
        ""
      when Array
        yaml.as_a.map { |item| stringify_value(item) }.join(",")
      when Hash
        yaml.to_json
      else
        yaml.to_s
      end
    end
    
    # Validate playbook structure
    def self.validate(playbook : Playbook) : Array(String)
      warnings = [] of String

      playbook.plays.each_with_index do |play, play_index|
        # Check for tasks
        if play.tasks.empty? && play.handlers.empty?
          warnings << "Play #{play_index + 1} '#{play.name}' has no tasks"
        end

        # Check for unimplemented plugins (recursing into block/rescue/always)
        flatten_tasks(play.tasks).each do |task|
          unless AVAILABLE_PLUGINS.includes?(task.module_name)
            warnings << "Task '#{task.name}' uses unimplemented plugin: #{task.module_name}"
          end
        end
      end

      warnings
    end

    # Get statistics about playbook
    def self.stats(playbook : Playbook) : Hash(String, Int32)
      stats = {
        "plays"         => playbook.plays.size,
        "tasks"         => 0,
        "handlers"      => 0,
        "modules_used"  => Set(String).new.size,
      }

      modules = Set(String).new

      playbook.plays.each do |play|
        flat_tasks = flatten_tasks(play.tasks)
        flat_handlers = flatten_tasks(play.handlers)

        stats["tasks"] += flat_tasks.size
        stats["handlers"] += flat_handlers.size

        flat_tasks.each { |task| modules.add(task.module_name) }
        flat_handlers.each { |handler| modules.add(handler.module_name) }
      end

      stats["modules_used"] = modules.size
      stats
    end

    # Expands block: tasks into their nested tasks (recursively, through
    # block/rescue/always), dropping the "_block" pseudo-task entries
    # themselves so callers only see real module invocations.
    private def self.flatten_tasks(tasks : Array(Task)) : Array(Task)
      tasks.flat_map do |task|
        if task.block?
          flatten_tasks(task.block_tasks || [] of Task) +
            flatten_tasks(task.rescue_tasks || [] of Task) +
            flatten_tasks(task.always_tasks || [] of Task)
        else
          [task]
        end
      end
    end
  end
end
