require "yaml"
require "json"
require "./playbook_parser"

module CrystalPlay
  # RoleLoader - resolves and loads roles: entries for a play.
  #
  # A role is a directory (roles/<name>/) with a conventional layout:
  #   tasks/main.yml, handlers/main.yml, defaults/main.yml, vars/main.yml,
  #   meta/main.yml, files/, templates/
  #
  # Role search path mirrors Ansible's common case: <playbook_dir>/roles/<name>,
  # then ./roles/<name> relative to the working directory. Ansible also
  # searches ANSIBLE_ROLES_PATH and a few other locations; not implemented.
  module RoleLoader
    # Loads every entry in a play's `roles:` list (plus their meta/main.yml
    # dependencies, recursively), in order. Returns {tasks, handlers} to
    # prepend to the play - Ansible runs role tasks before the play's own
    # tasks: (pre_tasks:/post_tasks: aren't implemented).
    def self.load_roles(roles_yaml : Array(YAML::Any), play : Play, playbook_dir : String) : {Array(Task), Array(Task)}
      seen = Set(String).new
      tasks = [] of Task
      handlers = [] of Task

      roles_yaml.each do |entry|
        name, invocation_vars, invocation_tags = parse_role_entry(entry)
        load_role(name, invocation_vars, invocation_tags, play, playbook_dir, seen, tasks, handlers)
      end

      {tasks, handlers}
    end

    # A roles: entry is either a bare string ("common") or a mapping with
    # role:/name: (+ optional vars:/tags:, and Ansible also treats any
    # other top-level key as a role var - `roles: [{role: app, port: 8080}]`).
    private def self.parse_role_entry(entry : YAML::Any) : {String, Hash(String, JSON::Any), Array(String)}
      if bare_name = entry.as_s?
        return {bare_name, Hash(String, JSON::Any).new, [] of String}
      end

      hash = entry.as_h
      name = (hash["role"]? || hash["name"]?).try(&.as_s)
      raise "Role entry missing 'role' or 'name'" unless name

      vars = Hash(String, JSON::Any).new
      if vars_yaml = hash["vars"]?.try(&.as_h?)
        vars_yaml.each { |key, value| vars[key.to_s] = JSON.parse(value.to_json) }
      end

      reserved = {"role", "name", "vars", "tags"}
      hash.each do |key, value|
        key_str = key.to_s
        next if reserved.includes?(key_str)
        vars[key_str] = JSON.parse(value.to_json)
      end

      tags = hash["tags"]?.try(&.as_a?).try(&.map(&.as_s)) || [] of String

      {name, vars, tags}
    end

    private def self.load_role(
      name : String,
      invocation_vars : Hash(String, JSON::Any),
      invocation_tags : Array(String),
      play : Play,
      playbook_dir : String,
      seen : Set(String),
      tasks : Array(Task),
      handlers : Array(Task),
    )
      return if seen.includes?(name)
      seen.add(name)

      role_dir = resolve_role_dir(name, playbook_dir)
      unless role_dir
        raise "Role not found: #{name} (looked under #{File.join(playbook_dir, "roles", name)} and #{File.join("roles", name)})"
      end

      # meta/main.yml dependencies run BEFORE this role's own tasks.
      load_meta_dependencies(role_dir, play, playbook_dir, seen, tasks, handlers)

      defaults = load_vars_file(File.join(role_dir, "defaults", "main.yml"))
      role_vars = load_vars_file(File.join(role_dir, "vars", "main.yml"))
      invocation_vars.each { |key, value| role_vars[key] = value } # invocation vars win over vars/main.yml

      files_dir = existing_dir(File.join(role_dir, "files"))
      templates_dir = existing_dir(File.join(role_dir, "templates"))

      role_tasks = load_tasks_file(File.join(role_dir, "tasks", "main.yml"), play)
      role_handlers = load_tasks_file(File.join(role_dir, "handlers", "main.yml"), play)

      (role_tasks + role_handlers).each do |task|
        task.role_defaults = defaults
        task.role_vars = role_vars
        task.role_files_dir = files_dir
        task.role_templates_dir = templates_dir
        task.tags = (task.tags + invocation_tags).uniq
      end

      tasks.concat(role_tasks)
      handlers.concat(role_handlers)
    end

    private def self.load_meta_dependencies(role_dir : String, play : Play, playbook_dir : String, seen : Set(String), tasks : Array(Task), handlers : Array(Task))
      meta_path = File.join(role_dir, "meta", "main.yml")
      return unless File.exists?(meta_path)

      meta_yaml = YAML.parse(File.read(meta_path))
      deps = meta_yaml["dependencies"]?.try(&.as_a?)
      return unless deps

      deps.each do |dep|
        dep_name, dep_vars, dep_tags = parse_role_entry(dep)
        load_role(dep_name, dep_vars, dep_tags, play, playbook_dir, seen, tasks, handlers)
      end
    end

    private def self.resolve_role_dir(name : String, playbook_dir : String) : String?
      [File.join(playbook_dir, "roles", name), File.join("roles", name)].find { |dir| Dir.exists?(dir) }
    end

    private def self.existing_dir(path : String) : String?
      Dir.exists?(path) ? path : nil
    end

    private def self.load_vars_file(path : String) : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      return result unless File.exists?(path)

      yaml = YAML.parse(File.read(path))
      if hash = yaml.as_h?
        hash.each { |key, value| result[key.to_s] = JSON.parse(value.to_json) }
      end

      result
    end

    private def self.load_tasks_file(path : String, play : Play) : Array(Task)
      return [] of Task unless File.exists?(path)

      yaml = YAML.parse(File.read(path))
      return [] of Task unless yaml.as_a?

      PlaybookParser.parse_tasks(yaml.as_a, play, "task in #{path}")
    end
  end
end
