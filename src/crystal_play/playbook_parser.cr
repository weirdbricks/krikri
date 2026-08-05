require "yaml"
require "./loop_resolver"
require "./role_loader"
require "./vault"

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
    # loop:/with_items:/with_dict:/with_nested:/with_indexed_items: given as
    # a Jinja variable reference ("{{ some_var }}") rather than a literal
    # inline list/dict. Unresolvable at parse time since the YAML value is
    # just a scalar string until the variable context exists, so the raw
    # source keyword and template string are carried for the executor to
    # resolve at execution time (mirrors loop_fileglob).
    property loop_template_kind : String?
    property loop_template : String?
    # until: / retries: / delay: - retry a task until a condition passes.
    property until_condition : String?
    property retries : Int32
    property delay : Int32
    # changed_when: / failed_when: - override the module's own changed/failed
    # verdict with a condition evaluated against the task's result (accessible
    # via its own register: name, same as any other post-task condition; a
    # bare literal like "false" needs no register: at all). Same string/eval
    # pipeline as when_condition/until_condition: substituted for {{ }}
    # expressions, then handed to ConditionalEvaluator.
    property changed_when : String?
    property failed_when : String?
    # delegate_to: - run this task's actual module/connection against a
    # different host than the one the play is iterating (e.g. "localhost"),
    # while variables/facts/register/stats still belong to the original
    # host. May be templated ({{ vars }}), so kept as a raw string and
    # resolved at execution time (same reasoning as include_file).
    property delegate_to : String?
    # run_once: - only actually execute this task for the first host in
    # the play; later hosts skip it outright (no output/stats), same as
    # real Ansible.
    property run_once : Bool
    # async: / poll: - run the module in the background (as a detached OS
    # process, not a Fiber, so it outlives the poll loop) up to async:
    # seconds, checking every poll: seconds (default 10, matching real
    # Ansible) until it finishes or the async: timeout elapses; poll: 0
    # returns immediately with the job id instead of waiting at all.
    # Local connections only - see TaskExecutor#execute_async.
    property async_seconds : Int32?
    property poll_seconds : Int32?
    # block: / rescue: / always: - only set when module_name == "_block"
    # (a pseudo-module marking this Task as a block rather than a plugin
    # invocation). Blocks can nest, since these are themselves Task lists.
    property block_tasks : Array(Task)?
    property rescue_tasks : Array(Task)?
    property always_tasks : Array(Task)?
    # Set on every task loaded from a role (tasks/main.yml and
    # handlers/main.yml alike) by RoleLoader. role_defaults is the lowest
    # precedence tier (role's defaults/main.yml); role_vars sits above
    # play/host vars but below the task's own vars: (role's vars/main.yml,
    # merged with the role invocation's own vars:). role_files_dir/
    # role_templates_dir let the executor resolve a copy:/template: src:
    # relative to the role's files//templates/ directory, since the
    # plugin subprocess itself has no concept of roles.
    property role_defaults : Hash(String, JSON::Any)?
    property role_vars : Hash(String, JSON::Any)?
    property role_files_dir : String?
    property role_templates_dir : String?
    # include_tasks: - only set when module_name == "_include_tasks".
    # Unlike import_tasks (resolved at parse time), the file path may be
    # templated ({{ vars }}) and isn't resolved until this task actually
    # runs, so both the raw path and the directory to resolve it against
    # (wherever the include_tasks: line itself lives) are carried on the
    # Task for the executor to use at run time.
    property include_file : String?
    property include_file_dir : String?
    # vars: on an include_tasks: statement - visible to every task in the
    # included file (unlike import_tasks:'s vars:, which is merged
    # directly into each imported task at parse time, this has to be
    # carried on the Task and propagated at execution time, same as loop:'s
    # item).
    property include_vars : Hash(String, JSON::Any)?
    # include_role: - only set when module_name == "_include_role". The
    # dynamic counterpart to a roles: list entry: resolved at execution
    # time (role name may be templated), via RoleLoader, same as roles:.
    property include_role_name : String?
    property include_role_vars : Hash(String, JSON::Any)?
    property include_role_dir : String?

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
      @loop_template_kind = nil
      @loop_template = nil
      @until_condition = nil
      @retries = 3
      @delay = 5
      @changed_when = nil
      @failed_when = nil
      @delegate_to = nil
      @run_once = false
      @async_seconds = nil
      @poll_seconds = nil
      @block_tasks = nil
      @rescue_tasks = nil
      @always_tasks = nil
      @role_defaults = nil
      @role_vars = nil
      @role_files_dir = nil
      @role_templates_dir = nil
      @include_file = nil
      @include_file_dir = nil
      @include_vars = nil
      @include_role_name = nil
      @include_role_vars = nil
      @include_role_dir = nil
    end

    def block? : Bool
      @module_name == "_block"
    end

    def include_tasks? : Bool
      @module_name == "_include_tasks"
    end

    def include_role? : Bool
      @module_name == "_include_role"
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
    # these are ansible.builtin.* (bundled with ansible-core); two
    # exceptions verified against a real ansible-core install (not
    # assumed): authorized_key lives in the separate ansible.posix
    # collection, and archive/unarchive live in community.general - neither
    # ships with ansible-core itself.
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
      "ansible.builtin.stat",
      "ansible.builtin.find",
      "community.general.archive",
      "ansible.builtin.unarchive",
      "ansible.builtin.yum_repository",
      "ansible.builtin.apt_repository",
      "ansible.posix.mount",
      "ansible.posix.sysctl",
      "community.general.ufw",
      "ansible.posix.firewalld",
      "ansible.builtin.async_status",
      "community.docker.docker_image",
      "community.docker.docker_network",
      "community.docker.docker_container",
      "community.mysql.mysql_db",
      "community.mysql.mysql_user",
      "community.postgresql.postgresql_db",
      "community.postgresql.postgresql_user",
      "community.postgresql.postgresql_privs",
      "ansible.builtin.set_fact",
      "ansible.builtin.get_url",
      "ansible.builtin.blockinfile",
      "ansible.builtin.uri",
      "ansible.builtin.assert",
      "ansible.builtin.wait_for",
      "ansible.builtin.fetch",
      "ansible.builtin.pause",
    ]

    # Parse playbook from file
    def self.parse(path : String) : Playbook
      unless File.exists?(path)
        raise "Playbook file not found: #{path}"
      end

      content = Vault.maybe_decrypt(File.read(path))
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

      playbook_dir = File.dirname(path)

      yaml.as_a.each_with_index do |play_yaml, index|
        if import_path = extract_import_playbook(play_yaml)
          begin
            imported = parse(File.expand_path(import_path, playbook_dir))
            playbook.plays.concat(imported.plays)
          rescue ex
            puts "Warning: Failed to import playbook '#{import_path}': #{ex.message}".colorize(:yellow)
          end
          next
        end

        begin
          play = parse_play(play_yaml, index, playbook_dir)
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

    # import_playbook: is only valid at the top level of a playbook (a list
    # item alongside plays, not inside tasks:) - "{import_playbook: path}"
    # rather than a normal play mapping (which requires 'hosts').
    private def self.extract_import_playbook(yaml : YAML::Any) : String?
      yaml.as_h?.try(&.["import_playbook"]?).try(&.as_s?)
    end

    # Parse a single play
    private def self.parse_play(yaml : YAML::Any, index : Int32, playbook_dir : String) : Play
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
          play.vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json))
        end
      end

      # Parse tags
      if tags_yaml = yaml["tags"]?.try(&.as_a?)
        play.tags = tags_yaml.map(&.as_s)
      end

      # Parse roles: - their tasks/handlers run BEFORE the play's own
      # tasks:/handlers: (matching Ansible; pre_tasks:/post_tasks: aren't
      # implemented, so this is simplified to just roles-then-tasks).
      role_tasks = [] of Task
      role_handlers = [] of Task
      if roles_yaml = yaml["roles"]?.try(&.as_a?)
        role_tasks, role_handlers = RoleLoader.load_roles(roles_yaml, play, playbook_dir)
      end

      # Parse tasks
      own_tasks = [] of Task
      if tasks_yaml = yaml["tasks"]?.try(&.as_a?)
        own_tasks = parse_tasks(tasks_yaml, play, "task in play '#{name}'", playbook_dir)
      end
      play.tasks = role_tasks + own_tasks

      # Parse handlers
      own_handlers = [] of Task
      if handlers_yaml = yaml["handlers"]?.try(&.as_a?)
        own_handlers = parse_tasks(handlers_yaml, play, "handler", playbook_dir)
      end
      play.handlers = role_handlers + own_handlers

      play
    end

    # Parse a list of task-shaped YAML nodes, skipping (with a warning) any
    # individual entry that fails to parse rather than failing the whole
    # list. Shared by play.tasks, play.handlers, block/rescue/always, and
    # (via RoleLoader) a role's tasks/main.yml and handlers/main.yml -
    # public for that last one. file_dir is the directory of whichever YAML
    # file tasks_yaml came from - used to resolve import_tasks:/
    # include_tasks: paths relative to that file (not the top-level
    # playbook), and passed down unchanged for block/rescue/always since
    # those stay within the same file.
    def self.parse_tasks(tasks_yaml : Array(YAML::Any), play : Play, context : String, file_dir : String) : Array(Task)
      tasks = [] of Task

      tasks_yaml.each_with_index do |task_yaml, index|
        begin
          if imported = try_parse_import_tasks(task_yaml, play, file_dir)
            tasks.concat(imported)
          else
            tasks << parse_task(task_yaml, index, play, file_dir)
          end
        rescue ex
          puts "Warning: Skipping #{context} #{index + 1}: #{ex.message}".colorize(:yellow)
        end
      end

      tasks
    end

    # import_tasks: is resolved at PARSE time - the imported file's tasks
    # are spliced directly into the caller's task list (returning
    # Array(Task) rather than a single wrapping Task, unlike block:).
    # Per ansible-doc: "Most keywords, including loops and conditionals,
    # only apply to the imported tasks, not to this statement itself" - so
    # the import's own when:/tags: are applied to EACH imported task
    # individually. loop: is not supported on import_tasks (use
    # include_tasks instead) and is simply ignored here. Returns nil when
    # the YAML node isn't an import_tasks: entry at all.
    private def self.try_parse_import_tasks(yaml : YAML::Any, play : Play, file_dir : String) : Array(Task)?
      hash = yaml.as_h?
      return nil unless hash

      import_value = hash["import_tasks"]?
      return nil unless import_value

      file_rel = import_value.as_h?.try(&.["file"]?).try(&.as_s?) || import_value.as_s?
      raise "import_tasks: missing a file path" unless file_rel

      resolved_path = File.expand_path(file_rel, file_dir)
      raise "Imported tasks file not found: #{resolved_path}" unless File.exists?(resolved_path)

      imported_yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
      raise "Imported tasks file must be a YAML list: #{resolved_path}" unless imported_yaml.as_a?

      imported_tasks = parse_tasks(imported_yaml.as_a, play, "task in imported #{resolved_path}", File.dirname(resolved_path))

      import_when = hash["when"]?.try { |v| safe_yaml_to_string(v) }
      import_tags = hash["tags"]?.try(&.as_a?).try(&.map(&.as_s)) || [] of String
      import_vars = Hash(String, JSON::Any).new
      if vars_yaml = hash["vars"]?.try(&.as_h?)
        vars_yaml.each { |key, value| import_vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
      end

      imported_tasks.each do |task|
        if import_when
          task.when_condition = task.when_condition ? "(#{task.when_condition}) and (#{import_when})" : import_when
        end
        task.tags = (task.tags + import_tags).uniq
        import_vars.each { |key, value| task.vars[key] = value }
      end

      imported_tasks
    end

    # Loop source keywords that support a plain literal (array or hash) at
    # parse time, in the same priority order used when picking a loop
    # source in parse_task. Checked here for a scalar "{{ ... }}" template
    # value once none of them matched literally.
    LOOP_TEMPLATE_KEYS = %w[loop with_items with_dict with_nested with_indexed_items]

    # If task_hash has one of the loop-source keywords set to a scalar
    # string that looks like a Jinja variable reference (rather than a
    # literal inline list/dict), return {keyword, template string}.
    private def self.find_loop_template(task_hash : Hash(YAML::Any, YAML::Any)) : {String, String}?
      LOOP_TEMPLATE_KEYS.each do |key|
        value = task_hash[key]?
        next unless value
        str = value.as_s?
        next unless str && str.includes?("{{")
        return {key, str}
      end
      nil
    end

    # Parse a single task
    private def self.parse_task(yaml : YAML::Any, index : Int32, play : Play, file_dir : String) : Task
      unless yaml.as_h?
        raise "Task must be a YAML mapping (hash)"
      end

      task_hash = yaml.as_h

      # Get task name
      name = task_hash["name"]?.try(&.as_s) || "Task #{index + 1}"

      if block_yaml = task_hash["block"]?.try(&.as_a?)
        return parse_block_task(name, task_hash, block_yaml, play, file_dir)
      end

      if include_yaml = task_hash["include_tasks"]?
        return parse_include_tasks(name, task_hash, include_yaml, play, file_dir)
      end

      if include_role_yaml = task_hash["include_role"]?.try(&.as_h?)
        return parse_include_role(name, task_hash, include_role_yaml, play, file_dir)
      end

      # Find the module (first key that's not a special keyword)
      special_keys = ["name", "when", "register", "ignore_errors", "check_mode",
                      "diff", "become", "become_user", "tags", "with_items", "loop",
                      "with_dict", "with_fileglob", "with_nested", "with_sequence",
                      "with_indexed_items", "until", "retries", "delay",
                      "notify", "changed_when", "failed_when", "delegate_to", "run_once",
                      "async", "poll", "vars",
                      "block", "rescue", "always", "import_tasks", "include_tasks", "include_role"]

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

      # Parse task-level vars: - a real, previously-shipped gap: nothing
      # here ever read this key into task.vars for a plain task (only
      # import_tasks:'s own vars: - a separate mechanism, see
      # parse_import_tasks above - was ever wired up), so a task-level
      # var was silently invisible everywhere that reads task.vars
      # (VariableContext#build folds it in at highest priority), not
      # just in when:/assert: that: - {{ }} substitution was equally
      # broken, since it draws from the exact same vars_context.
      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars_yaml.each { |key, value| task.vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
      end

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
      elsif template_source = find_loop_template(task_hash)
        # loop:/with_items:/with_dict:/with_nested:/with_indexed_items: given
        # as a "{{ variable }}" reference: not a literal array/hash at parse
        # time, so stash the raw keyword + template string for the executor
        # to resolve once the variable context exists.
        task.loop_template_kind = template_source[0]
        task.loop_template = template_source[1]
      end

      # Parse until / retries / delay
      task.until_condition = task_hash["until"]?.try { |v| safe_yaml_to_string(v) }
      task.retries = task_hash["retries"]?.try { |v| safe_yaml_to_string(v).to_i? } || 3
      task.delay = task_hash["delay"]?.try { |v| safe_yaml_to_string(v).to_i? } || 5

      # Parse changed_when / failed_when
      task.changed_when = task_hash["changed_when"]?.try { |v| safe_yaml_to_string(v) }
      task.failed_when = task_hash["failed_when"]?.try { |v| safe_yaml_to_string(v) }

      # Parse delegate_to / run_once
      task.delegate_to = task_hash["delegate_to"]?.try { |v| safe_yaml_to_string(v) }
      task.run_once = task_hash["run_once"]?.try(&.as_bool) || false

      # Parse async / poll
      task.async_seconds = task_hash["async"]?.try { |v| safe_yaml_to_string(v).to_i? }
      task.poll_seconds = task_hash["poll"]?.try { |v| safe_yaml_to_string(v).to_i? }

      task
    end

    # Parse a block: task - block:/rescue:/always: are each an array of
    # nested tasks (which may themselves be blocks, so this recurses
    # naturally through parse_tasks -> parse_task -> parse_block_task).
    private def self.parse_block_task(name : String, task_hash : Hash(YAML::Any, YAML::Any), block_yaml : Array(YAML::Any), play : Play, file_dir : String) : Task
      task = Task.new(name, "_block")
      task.block_tasks = parse_tasks(block_yaml, play, "task in block '#{name}'", file_dir)

      if rescue_yaml = task_hash["rescue"]?.try(&.as_a?)
        task.rescue_tasks = parse_tasks(rescue_yaml, play, "task in rescue of block '#{name}'", file_dir)
      end

      if always_yaml = task_hash["always"]?.try(&.as_a?)
        task.always_tasks = parse_tasks(always_yaml, play, "task in always of block '#{name}'", file_dir)
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

    # Parse an include_tasks: task - unlike import_tasks (spliced into the
    # task list at parse time), this is resolved at EXECUTION time: the
    # file path may be templated, when:/tags:/loop: apply to the include
    # statement itself (once, or once per loop item) rather than each
    # included task individually, and the executor evaluates it via
    # TaskExecutor#execute_include_tasks.
    private def self.parse_include_tasks(name : String, task_hash : Hash(YAML::Any, YAML::Any), include_yaml : YAML::Any, play : Play, file_dir : String) : Task
      file_rel = include_yaml.as_h?.try(&.["file"]?).try(&.as_s?) || include_yaml.as_s?
      raise "include_tasks: missing a file path" unless file_rel

      task = Task.new(name, "_include_tasks")
      task.include_file = file_rel
      task.include_file_dir = file_dir

      task.when_condition = task_hash["when"]?.try { |v| safe_yaml_to_string(v) }
      task.ignore_errors = task_hash["ignore_errors"]?.try(&.as_bool) || false
      task.become = task_hash["become"]?.try(&.as_bool) || play.become
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user

      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end

      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars = Hash(String, JSON::Any).new
        vars_yaml.each { |key, value| vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
        task.include_vars = vars
      end

      # loop:/with_items: repeats the whole include once per item (unlike
      # import_tasks, which doesn't support loop: at all). Only these two
      # loop sources are supported here, not the full with_dict/with_nested/
      # etc set a normal task gets - a reasonable scope limit given how
      # rarely those combine with include_tasks in practice.
      if loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop_items = loop_yaml.map { |item| JSON.parse(item.to_json) }
      elsif with_items = task_hash["with_items"]?.try(&.as_a?)
        task.loop_items = with_items.map { |item| JSON.parse(item.to_json) }
      end

      task
    end

    # Parse an include_role: task - the dynamic counterpart to a roles:
    # list entry, resolved at execution time via
    # TaskExecutor#execute_include_role. name: is required; unlike a
    # roles: entry, vars: is a normal sibling task keyword here (not
    # nested inside include_role: itself) - confirmed via `ansible-doc -s
    # ansible.builtin.include_role`. apply:/defaults_from:/handlers_from:/
    # public:/rescuable:/rolespec_validate: aren't implemented.
    # allow_duplicates: isn't implemented either - every include_role call
    # loads the role fresh, matching its default (true) but not honoring
    # an explicit false.
    private def self.parse_include_role(name : String, task_hash : Hash(YAML::Any, YAML::Any), include_role_yaml : Hash(YAML::Any, YAML::Any), play : Play, file_dir : String) : Task
      role_name = include_role_yaml["name"]?.try(&.as_s)
      raise "include_role: missing required 'name'" unless role_name

      task = Task.new(name, "_include_role")
      task.include_role_name = role_name
      task.include_role_dir = file_dir

      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars = Hash(String, JSON::Any).new
        vars_yaml.each { |key, value| vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
        task.include_role_vars = vars
      end

      task.when_condition = task_hash["when"]?.try { |v| safe_yaml_to_string(v) }
      task.ignore_errors = task_hash["ignore_errors"]?.try(&.as_bool) || false
      task.become = task_hash["become"]?.try(&.as_bool) || play.become
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user

      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end

      if loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop_items = loop_yaml.map { |item| JSON.parse(item.to_json) }
      elsif with_items = task_hash["with_items"]?.try(&.as_a?)
        task.loop_items = with_items.map { |item| JSON.parse(item.to_json) }
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
          if module_name == "ansible.builtin.assert" && key.to_s == "that"
            # `that:` is a list of independent condition strings (or, per
            # real Ansible, a single bare string) - stringify_value's own
            # Array handling joins with a comma, which would corrupt any
            # condition that itself contains one (e.g. a list literal like
            # `x in [1, 2, 3]`), so this is JSON-encoded instead and
            # decoded back into an Array(String) on the plugin side.
            conditions = value.as_a?.try(&.map { |item| stringify_value(item) }) || [stringify_value(value)]
            params[key.to_s] = conditions.to_json
          else
            params[key.to_s] = Vault.maybe_decrypt(stringify_value(value))
          end
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
        # A list of scalars (real Ansible's `type: list, elements: str/int`)
        # stays comma-joined, the format every existing plugin's list
        # params already expect. A list of dicts (`elements: dict`, e.g.
        # docker_container's networks:) can't be represented that way at
        # all - comma-joining each element's own `yaml.to_json` Hash
        # output produces several JSON objects glued together with commas
        # and no wrapping brackets, which isn't valid JSON once there's
        # more than one element, and is indistinguishable from a single
        # scalar for exactly one - so it's emitted as a real JSON array
        # instead, decodable via `JSON.parse(json).as_a`.
        if yaml.as_a.any? { |item| item.raw.is_a?(Hash) }
          yaml.to_json
        else
          yaml.as_a.map { |item| stringify_value(item) }.join(",")
        end
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
        "plays"        => playbook.plays.size,
        "tasks"        => 0,
        "handlers"     => 0,
        "modules_used" => Set(String).new.size,
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
        elsif task.include_tasks? || task.include_role?
          # Dynamic: the included content (and even the file path/role
          # name, which may be templated) isn't known until this task
          # actually runs, so there's nothing to flatten into and nothing
          # to warn about as an "unimplemented plugin" here.
          [] of Task
        else
          [task]
        end
      end
    end
  end
end
