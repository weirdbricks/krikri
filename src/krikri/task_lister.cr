require "./playbook_parser"
require "./tag_filter"

module Krikri
  # `--list-tasks` and `--syntax-check`, reproducing
  # ansible-playbook's own output shape. Every detail below was captured
  # from a ansible-core 2.19.4 run rather than invented:
  #
  #     \nplaybook: p.yml\n
  #     \n  play #1 (localhost): First play\tTAGS: []
  #         tasks:
  #           plain task\tTAGS: []
  #           tagged task\tTAGS: [alpha, beta]
  #           inner task\tTAGS: [inner, outer]
  #
  # Non-obvious specifics it matches:
  #   * tags are sorted alphabetically, not listed in source order, and a
  #     task's own tags are unioned with every enclosing block's
  #   * a task inside a block IS listed, but tasks under that block's
  #     `always:` are NOT
  #   * a role's tasks are listed as "rolename : taskname"
  #   * --tags/--skip-tags filter the listing, and a play left with no
  #     tasks still prints its header and its bare "tasks:" line
  #   * the separator between the name and TAGS is a literal TAB
  module TaskLister
    def self.syntax_check(playbook : Playbook) : Nil
      # A parse failure never reaches here - krikri-playbook.cr's own parse
      # rescue has already reported it and exited 4, which is exactly
      # what ansible-playbook does for --syntax-check on a broken
      # playbook. So reaching this point IS the success case.
      puts ""
      puts "playbook: #{playbook.path}"
    end

    def self.list_tasks(playbook : Playbook, only : Array(String), skip : Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"
        puts "    tasks:"

        TagFilter.apply(expand_static_imports(play.tasks, play, File.dirname(playbook.path)), only, skip).each do |task|
          emit(task, play.tags)
        end
      end
    end

    # --list-tags: one line per play with the sorted union of every tag
    # on every task in it (block tags included, via the same inheritance
    # --list-tasks uses).
    def self.list_tags(playbook : Playbook, only : Array(String), skip : Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"

        tags = [] of String
        # Same static-import expansion --list-tasks applies: real computes
        # the tag union over the COMPILED task list (play.compile()), so a
        # static import_role:'s loaded tasks contribute their own tags.
        selected = expand_static_imports(play.tasks, play, File.dirname(playbook.path))
        # Without --tags/--skip-tags real lists every tag, `never` included.
        selected = only.empty? && skip.empty? ? selected : TagFilter.apply(selected, only, skip)
        selected.each do |task|
          collect_tags(task, play.tags, tags)
        end
        puts "      TASK TAGS: [#{tags.uniq.sort!.join(", ")}]"
      end
    end

    # --list-hosts: the play's host pattern, then the hosts it matches,
    # sorted. *resolve* is handed in rather than an Inventory so this
    # module keeps its single dependency on the parser.
    def self.list_hosts(playbook : Playbook, & : Play -> Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"
        # Ansible prints the pattern as a Python list repr, e.g.
        # `pattern: ['web']` - verified against ansible-core 2.19.4.
        puts "    pattern: [#{pattern_list(play).map { |entry| "'#{entry}'" }.join(", ")}]"

        names = yield(play)
        puts "    hosts (#{names.size}):"
        names.sort.each { |name| puts "      #{name}" }
      end
    end

    private def self.pattern_list(play : Play) : Array(String)
      hosts = play.hosts
      hosts.is_a?(Array) ? hosts : hosts.split(",").map(&.strip).reject(&.empty?)
    end

    private def self.collect_tags(task : Task, inherited : Array(String), into : Array(String)) : Nil
      effective = (task.tags + inherited).uniq

      if task.block?
        (task.block_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        (task.rescue_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        (task.always_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        return
      end

      effective.each { |tag| into << tag }
    end

    private def self.host_pattern(play : Play) : String
      hosts = play.hosts
      hosts.is_a?(Array) ? hosts.join(",") : hosts
    end

    # Replaces every STATIC import_role: statement with the role's own
    # loaded tasks, recursively - real's --list-tasks/--list-tags walk
    # play.compile(), which splices static imports at parse time, so the
    # import statement itself never appears and the loaded tasks do (a
    # dynamic include_role: statement DOES appear, unexpanded). Tags
    # merge exactly the way a roles: entry's do: RoleLoader unions the
    # import statement's own tags onto every loaded task, and any
    # enclosing block/play tags arrive through emit/collect_tags'
    # inherited parameter afterwards.
    private def self.expand_static_imports(tasks : Array(Task), play : Play, playbook_dir : String, seen_roles : Array(String) = [] of String) : Array(Task)
      tasks.flat_map do |task|
        if task.block?
          {% begin %}
          {% for field in ["block_tasks", "rescue_tasks", "always_tasks"] %}
            if nested = task.{{ field.id }}
              task.{{ field.id }} = expand_static_imports(nested, play, playbook_dir, seen_roles)
            end
          {% end %}
          {% end %}
          [task]
        elsif task.include_role? && task.is_static_import?
          expand_one_import(task, play, playbook_dir, seen_roles)
        else
          [task]
        end
      end
    end

    private def self.expand_one_import(task : Task, play : Play, playbook_dir : String, seen_roles : Array(String)) : Array(Task)
      raw_name = task.include_role_name
      return [task] unless raw_name

      role_name = resolve_import_role_name(raw_name, play)
      return [task] if role_name.nil?
      return [task] if seen_roles.includes?(role_name)

      loaded = load_imported_role_tasks(task, play, role_name, playbook_dir)
      return [task] unless loaded

      expand_static_imports(loaded, play, task.include_role_dir || playbook_dir, seen_roles + [role_name])
    end

    # The parser validated a templated import_role: name against the
    # play's own vars at parse time (StaticImportRoleUndefinedError
    # otherwise aborts the whole parse), so by listing time it always
    # renders - but render it anyway (same context the parser used) and
    # fall back to leaving the statement listed if it somehow can't.
    # Returns nil when the statement should stay listed as-is.
    private def self.resolve_import_role_name(raw_name : String, play : Play) : String?
      role_name = raw_name.includes?("{{") ? (VarSubstitutor.new(vars: play.vars).substitute(raw_name) rescue raw_name) : raw_name
      return nil if role_name.empty? || role_name.includes?("{{")
      role_name
    end

    # Loads *task*'s static import_role: target the same way the runtime
    # include_role: path does (same parent-chain stamping as
    # executor_blocks_includes.cr's run_include_role_once, so a nested
    # import_role: inside the loaded role displays under ITS own name).
    # Returns nil when the load fails - a role that loaded fine at parse
    # time but fails to load now would be a krikri bug; listing the bare
    # statement beats crashing the listing for it.
    private def self.load_imported_role_tasks(task : Task, play : Play, role_name : String, playbook_dir : String) : Array(Task)?
      # Same parent-chain stamping the runtime include_role: path applies
      # (executor_blocks_includes.cr's run_include_role_once) so a nested
      # import_role: inside the loaded role displays under ITS own name.
      child_parent_names = (task.role_parent_names || [] of String) + (task.role_name ? [task.role_name.as(String)] : [] of String)
      child_parent_paths = (task.role_parent_paths || [] of String) + (task.role_path ? [task.role_path.as(String)] : [] of String)
      child_parent_defaults = task.role_defaults || Hash(String, JSON::Any).new

      tasks_from = task.include_role_tasks_from
      if tasks_from && tasks_from.includes?("{{")
        tasks_from = (VarSubstitutor.new(vars: play.vars).substitute(tasks_from) rescue tasks_from)
      end

      begin
        RoleLoader.load_single_role(
          role_name,
          task.include_role_vars || Hash(String, JSON::Any).new,
          # Only a STATIC import pushes its own tags onto the loaded tasks
          # (same rule the runtime executor applies).
          task.tags,
          play,
          task.include_role_dir || playbook_dir,
          tasks_from,
          child_parent_names,
          child_parent_paths,
          child_parent_defaults
        )[0]
      rescue
        nil
      end
    end

    private def self.emit(task : Task, inherited : Array(String)) : Nil
      effective = (task.tags + inherited).uniq

      if task.block?
        # Ansible lists a block's body but NOT its always: tasks
        # (verified: an `always:` entry never appears in --list-tasks
        # output). rescue: is likewise absent from the listing.
        (task.block_tasks || [] of Task).each { |nested| emit(nested, effective) }
        return
      end

      puts "      #{display_name(task)}\tTAGS: [#{effective.sort.join(", ")}]"
    end

    private def self.display_name(task : Task) : String
      # Real's listtasks CLI prints `task.action` (the directive key as
      # written, no role prefix) for a task with no `name:` of its own,
      # and `task.get_name()` - "role : name" - otherwise. The one
      # exception: a DYNAMIC include_role: statement is never role-
      # prefixed in the listing, named or not (real's IncludeRole task
      # loses its _role binding; live-verified vs 2.19.11: an include_
      # role: inside a role lists as "dynamic include statement" where
      # the sibling include_tasks: lists as "testrole : ..."). A static
      # import_role: statement never appears at all - it's spliced away
      # by #expand_static_imports before display_name runs.
      if task.has_explicit_name?
        if (role_name = task.role_name) && !role_name.empty? && !(task.include_role? && !task.is_static_import?)
          "#{role_name} : #{task.name}"
        else
          task.name
        end
      else
        task.written_action || task.name
      end
    end
  end
end
