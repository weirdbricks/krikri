require "yaml"
require "json"
require "system/user"
require "./playbook_parser"
require "./vault"

module Krikri
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
    # Whether *name* resolves to a real role directory, from the same
    # search path #resolve_role_dir already uses (collection role dirs,
    # playbook_dir/roles/name, ./roles/name relative to CWD, and
    # ANSIBLE_ROLES_PATH/Galaxy-default roles_paths) - exposed publicly
    # (resolve_role_dir itself is private) so PlaybookParser can do the
    # same existence check for a task-level `import_role:`, which real
    # Ansible resolves STATICALLY (before any task runs) exactly like a
    # play-level `roles:` entry or a meta/main.yml dependency already
    # does via #load_role's own RoleNotFoundError raise - previously
    # only those two call sites checked existence at all; a task-level
    # import_role: referencing a role never installed (buluma.revealmd's
    # own `import_role: name: buluma.service`, round 180) instead ran 5
    # of the role's OWN tasks first and only failed later at the runtime
    # `_include_role` dispatch, instead of refusing the whole playbook
    # up front the way real Ansible does (rc=1, zero tasks run).
    def self.role_exists?(name : String, playbook_dir : String) : Bool
      !resolve_role_dir(name, playbook_dir).nil?
    end

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
        load_role(name, invocation_vars, invocation_tags, play, playbook_dir, seen, tasks, handlers, play_scope: true)
      end

      {tasks, handlers}
    end

    # Loads a single role by name (plus its meta/main.yml dependencies) -
    # used by TaskExecutor#execute_include_role for include_role:, the
    # dynamic (execution-time) counterpart to a static roles: entry. Each
    # call gets its own fresh "seen" set, so - matching include_role's
    # allow_duplicates: true default - repeated include_role calls for the
    # same role name each load it again rather than being silently
    # deduplicated the way a role listed twice under roles: would be. An
    # explicit allow_duplicates: false isn't honored (dedup only happens
    # within a single call's own meta dependency chain).
    def self.load_single_role(name : String, invocation_vars : Hash(String, JSON::Any), invocation_tags : Array(String), play : Play, playbook_dir : String, tasks_from : String? = nil, parent_names : Array(String) = [] of String, parent_paths : Array(String) = [] of String, parent_defaults : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : {Array(Task), Array(Task)}
      seen = Set(String).new
      tasks = [] of Task
      handlers = [] of Task

      load_role(name, invocation_vars, invocation_tags, play, playbook_dir, seen, tasks, handlers, tasks_from, parent_names, parent_paths, parent_defaults)

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
      # `src:` is real Ansible's own `RoleRequirement` key - the SAME
      # class ansible-core uses both for a `requirements.yml` entry AND
      # for a role's `meta/main.yml` dependency, so a dependency written
      # `- src: some.role, version: v1.0.0` (copied from the galaxy-
      # requirements convention, common in real published roles) is
      # entirely normal, real syntax - not just "role"/"name". Missing
      # here meant ANY role with a `src:`-keyed meta dependency failed
      # to parse the name at all and raised, aborting the WHOLE
      # playbook parse (not just that one dependency) - found live via
      # andrewrothstein.github-release's own `meta/main.yml`
      # (`dependencies: [{src: andrewrothstein.unarchive-deps, version:
      # v1.0.9}]`), which real Ansible resolves and installs fine.
      name = (hash["role"]? || hash["name"]? || hash["src"]?).try(&.as_s)
      raise "Role entry missing 'role' or 'name'" unless name

      vars = Hash(String, JSON::Any).new
      if vars_yaml = hash["vars"]?.try(&.as_h?)
        vars_yaml.each { |key, value| vars[key.to_s] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value)) }
      end

      # `version`/`scm` are the other two `RoleRequirement` galaxy-source
      # keys that travel alongside `src:` - dependency-RESOLUTION
      # metadata (which tag/branch/protocol to fetch from), not role
      # vars, so they must be excluded here the same way `role`/`name`
      # already are (a `version: v1.0.9` var leaking into the role's own
      # vars context, e.g. via `{{ version }}`, would be a real
      # divergence from what real Ansible - which never exposes these
      # as vars either - provides).
      reserved = {"role", "name", "src", "version", "scm", "vars", "tags"}
      hash.each do |key, value|
        key_str = key.to_s
        next if reserved.includes?(key_str)
        vars[key_str] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))
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
      tasks_from : String? = nil,
      parent_names : Array(String) = [] of String,
      parent_paths : Array(String) = [] of String,
      parent_defaults : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
      # Whether this role's own defaults/vars join the PLAY-WIDE layers
      # every role can see (Play#all_role_defaults/#all_role_vars). True
      # for a static `roles:` entry and its meta dependencies, which real
      # Ansible loads at play setup; FALSE for include_role:, whose
      # vars/defaults real Ansible keeps scoped to that inclusion unless
      # it is `public: true` - contributing them here would expose them
      # to every later task in the play instead.
      play_scope : Bool = false,
    )
      # An already-loaded role contributes no defaults a second time -
      # its tasks (and their defaults) are already in the play.
      return Hash(String, JSON::Any).new if seen.includes?(name)
      seen.add(name)

      role_dir = resolve_role_dir(name, playbook_dir)
      unless role_dir
        raise RoleNotFoundError.new("Role not found: #{name} (looked under #{File.join(playbook_dir, "roles", name)} and #{File.join("roles", name)})")
      end
      # Real Ansible's `role_path` magic var is always an ABSOLUTE path -
      # resolve_role_dir's own search dirs can be relative (a bare "roles"
      # search root, or a relative ANSIBLE_ROLES_PATH entry), and that
      # relative-ness was leaking straight into task.role_path below.
      # Found benchmarking linux-system-roles.timesync's own `paths:
      # ["{{ role_path }}/vars"]` first_found idiom (real Ansible's own
      # convention, since role_path is documented as always-absolute):
      # resolve_first_found_root's `return path if path.starts_with?("/")`
      # early-return never fired for a relative role_path, so it went on
      # to prepend role_path a SECOND time on top of the already-
      # role_path-prefixed string Jinja had just substituted, producing
      # a doubled, nonexistent path ("./roles/x/./roles/x/vars/...") -
      # every candidate "not found", the whole lookup silently resolving
      # to "undefined" instead of the real vars file. Only reproduced
      # against a real remote host (a local/no-op connection's own
      # working directory setup happened to make the relative role_path
      # already effectively absolute-equivalent for File.exists?, masking
      # this everywhere else it's been benchmarked so far).
      role_dir = File.expand_path(role_dir)

      # ansible_collection_name - only set when this role was actually
      # invoked via its full `namespace.collection.role` FQCN (a real
      # collection role, not merely a bare role name that happens to
      # contain 2+ dots - vanishingly rare in practice).
      collection_name = (parts = name.split('.')).size >= 3 ? "#{parts[0]}.#{parts[1]}" : nil

      # meta/main.yml dependencies run BEFORE this role's own tasks - they
      # get the SAME parent_names as the declaring role itself (not
      # extended further), matching real Ansible: a dependency isn't
      # "nested inside" the declaring role's own tasks the way an
      # include_role: call is.
      dependency_defaults = load_meta_dependencies(role_dir, play, playbook_dir, seen, tasks, handlers, parent_names, parent_paths, parent_defaults, play_scope)

      defaults = load_vars_file_main(File.join(role_dir, "defaults"))
      # Real Ansible keeps a role's defaults visible for the rest of the
      # PLAY once that role has run, not just for tasks physically inside
      # that role's own files - a role invoked via `include_role:` from
      # inside another role's tasks (prometheus.prometheus's own `_common`
      # shared-logic role, invoked from every exporter role's own
      # configure.yml) still needs to see the CALLING role's defaults.
      # `parent_defaults` is the accumulated chain from every ancestor
      # role that led here (root-first merge order, so a NEARER ancestor's
      # default wins over a more distant one on a naming collision -
      # matches real Ansible's own "later-loaded role wins" precedence for
      # defaults); this role's own defaults win over all of them. Found
      # via that exact `_common` scenario: node_exporter's own `node_
      # exporter_textfile_dir` default (defaults/main.yml) went undefined
      # the moment its own `node_exporter.service.j2` template got
      # rendered from within _common's included tasks, even though real
      # Ansible keeps it in scope - `task.role_defaults` was previously
      # always just THIS role's own defaults, discarding the whole
      # ancestor chain.
      #
      # A meta/main.yml DEPENDENCY's own defaults are in scope for the
      # role that declares it, too - real Ansible loads a dependency
      # first and its defaults stay visible to the dependent role, which
      # is how the extremely common "role B declares role A as a
      # dependency and then references A's defaults" shape works at all
      # (`buluma.phpmyadmin`'s own `phpmyadmin_mysql_password: "{{
      # mysql_root_password }}"` reads that name straight out of its
      # `buluma.mysql` dependency's defaults/main.yml). Only the
      # ancestor chain (`parent_defaults`, an include_role: caller) was
      # carried before, so a dependency's defaults were loaded, used for
      # that dependency's OWN tasks, and then discarded - every such
      # cross-role reference silently resolved to nothing. Lower
      # precedence than this role's own defaults, matching real
      # Ansible's own dependency-then-self load order.
      defaults = parent_defaults.merge(dependency_defaults).merge(defaults)
      role_vars = load_vars_file_main(File.join(role_dir, "vars"))
      invocation_vars.each { |key, value| role_vars[key] = value } # invocation vars win over vars/main.yml

      # Contribute to the play-wide layers every role can see - see
      # Play#all_role_defaults for why real Ansible makes these visible
      # to roles that ran EARLIER too. Assigned in load order, so a
      # later role wins a name collision, which is what real Ansible
      # answers outside any role (verified: post_tasks: sees the LAST
      # role's value for a name two roles both define).
      if play_scope
        own_defaults = load_vars_file_main(File.join(role_dir, "defaults"))
        own_defaults.each { |key, value| play.all_role_defaults[key] = value }
        role_vars.each { |key, value| play.all_role_vars[key] = value }
      end

      files_dir = existing_dir(File.join(role_dir, "files"))
      templates_dir = existing_dir(File.join(role_dir, "templates"))
      vars_dir = existing_dir(File.join(role_dir, "vars"))

      # Known at parse time, before facts gathering - real Ansible's own
      # constraint for what import_tasks:'s own file path may reference
      # (see try_parse_import_tasks in playbook_parser.cr). role_vars
      # wins over defaults, matching normal precedence.
      known_vars = defaults.merge(role_vars)
      # tasks_from: loads tasks/<name>.yml instead of tasks/main.yml -
      # handlers/defaults/vars still always come from their normal
      # main.yml locations regardless (matching real Ansible: only the
      # entry-point TASKS file changes).
      # Real Ansible accepts tasks_from: with OR without the extension
      # (prometheus.prometheus's own roles write it both ways across
      # different calls - `tasks_from: install.yml` as well as bare
      # names elsewhere) - append .yml only when it's not already there.
      tasks_path = resolve_role_tasks_path(role_dir, tasks_from)
      role_tasks = load_tasks_file(tasks_path, play, known_vars)
      role_handlers = load_tasks_file(find_main_file(File.join(role_dir, "handlers")) || File.join(role_dir, "handlers", "main.yml"), play, known_vars)

      # The argument-spec "Validating arguments..." task only applies to
      # the role's own default ("main") entry point, not an arbitrary
      # tasks_from: file.
      if !tasks_from && (validation_task = load_argument_spec_validation_task(role_dir))
        role_tasks.unshift(validation_task)
      end

      (role_tasks + role_handlers).each do |task|
        task.role_defaults = defaults
        task.role_vars = role_vars
        task.role_files_dir = files_dir
        task.role_templates_dir = templates_dir
        task.role_vars_dir = vars_dir
        # include_role_dir must stay anchored to the ORIGINAL playbook's
        # own directory - real Ansible's role search paths are always
        # relative to the playbook root (or configured roles_path), never
        # to whatever tasks file happens to be currently executing.
        # parse_task sets it from the file_dir of the tasks/main.yml file
        # actually being parsed here (this role's own tasks dir, e.g.
        # roles/outer_role/tasks) - correct for include_tasks:'s OWN
        # relative file: resolution, but wrong for a nested include_role:
        # task's role lookup, which then searched roles/outer_role/tasks/
        # roles/<name> instead of the real <playbook_dir>/roles/<name>.
        # Any include_role: called directly from within a role's own
        # tasks/main.yml hit this (not just role-file text loaded further
        # via include_tasks) - previously unexercised by any existing
        # test, since the only prior include_role: coverage called it
        # from a PLAY's own tasks: list, never from inside a role.
        task.include_role_dir = playbook_dir
        task.role_name = name
        task.role_path = role_dir
        task.role_parent_names = parent_names
        task.role_parent_paths = parent_paths
        task.ansible_collection_name = collection_name
        task.tags = (task.tags + invocation_tags).uniq
      end

      tasks.concat(role_tasks)
      handlers.concat(role_handlers)

      # Returned so a DECLARING role can pick these up as its own
      # dependency defaults (see the `dependency_defaults` merge above).
      defaults
    end

    # tasks_from: loads tasks/<name>.yml instead of tasks/main.yml -
    # handlers/defaults/vars still always come from their normal main.yml
    # locations regardless (matching real Ansible: only the entry-point
    # TASKS file changes). Real Ansible accepts tasks_from: with OR
    # without the extension (prometheus.prometheus's own roles write it
    # both ways across different calls - `tasks_from: install.yml` as
    # well as bare names elsewhere) - append .yml only when it's not
    # already there.
    private def self.resolve_role_tasks_path(role_dir : String, tasks_from : String?) : String
      return find_main_file(File.join(role_dir, "tasks")) || File.join(role_dir, "tasks", "main.yml") unless tasks_from
      return File.join(role_dir, "tasks", tasks_from) if tasks_from.ends_with?(".yml") || tasks_from.ends_with?(".yaml") || tasks_from.ends_with?(".json")

      # Real Ansible resolves a bare tasks_from: name against ANY of its
      # accepted extensions.
      ext = %w[yml yaml json].find { |e| File.exists?(File.join(role_dir, "tasks", "#{tasks_from}.#{e}")) }
      File.join(role_dir, "tasks", "#{tasks_from}.#{ext || "yml"}")
    end

    # Returns the accumulated defaults of every dependency loaded (later
    # dependencies winning over earlier ones on a name collision, matching
    # real Ansible's load order), for the declaring role to merge under
    # its own - see `load_role`'s `dependency_defaults` comment.
    private def self.load_meta_dependencies(role_dir : String, play : Play, playbook_dir : String, seen : Set(String), tasks : Array(Task), handlers : Array(Task), parent_names : Array(String) = [] of String, parent_paths : Array(String) = [] of String, parent_defaults : Hash(String, JSON::Any) = Hash(String, JSON::Any).new, play_scope : Bool = false) : Hash(String, JSON::Any)
      collected = Hash(String, JSON::Any).new
      meta_path = find_main_file(File.join(role_dir, "meta")) || File.join(role_dir, "meta", "main.yml")
      return collected unless File.exists?(meta_path)

      meta_yaml = YAML.parse(Vault.maybe_decrypt(File.read(meta_path)))
      deps = meta_yaml["dependencies"]?.try(&.as_a?)
      return collected unless deps

      deps.each do |dep|
        dep_name, dep_vars, dep_tags = parse_role_entry(dep)
        dep_defaults = load_role(dep_name, dep_vars, dep_tags, play, playbook_dir, seen, tasks, handlers, nil, parent_names, parent_paths, parent_defaults, play_scope)
        collected.merge!(dep_defaults)
      end

      collected
    end

    private def self.resolve_role_dir(name : String, playbook_dir : String) : String?
      # A role name containing a path separator (absolute, or relative like
      # "../common_roles/foo") is used directly, matching real Ansible -
      # only a bare name ("common") is looked up under roles:/ search paths.
      if name.includes?('/')
        return name if Dir.exists?(name)
        joined = File.join(playbook_dir, name)
        return joined if Dir.exists?(joined)
        return nil
      end

      if collection_dir = resolve_collection_role_dir(name, playbook_dir)
        return collection_dir
      end

      search_dirs = [File.join(playbook_dir, "roles", name), File.join("roles", name)]
      search_dirs.concat(roles_paths.map { |base| File.join(base, name) })
      search_dirs.find { |dir| Dir.exists?(dir) }
    end

    # Real Ansible's role search also checks `ANSIBLE_ROLES_PATH` (colon-
    # separated, like `ANSIBLE_ROLES_PATH`/`ANSIBLE_COLLECTIONS_PATH`) and
    # its own default `roles_path`, which is where `ansible-galaxy role
    # install <namespace>.<name>` (the standard way to fetch a plain,
    # non-collection Galaxy role) puts things by default:
    # `~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles`.
    # `resolve_role_dir` previously only ever checked playbook-relative
    # `roles/<name>` dirs, so any Galaxy-installed role referenced by its
    # bare name (`robertdebock.httpd`, not a 3-part collection FQCN) failed
    # outright with "Role not found" the moment the working directory
    # wasn't also where the role happened to be vendored locally - the
    # collection-role lookup right above already got this treatment for
    # collection-shipped roles; bare Galaxy roles never did.
    private def self.roles_paths : Array(String)
      paths = [] of String

      if env_path = ENV["ANSIBLE_ROLES_PATH"]?
        paths.concat(env_path.split(':').reject(&.empty?))
      end

      paths << expand_home_path("~/.ansible/roles")
      paths << "/usr/share/ansible/roles"
      paths << "/etc/ansible/roles"

      paths
    end

    # A `namespace.collection.role_name` FQCN roles: entry (e.g.
    # `prometheus.prometheus.node_exporter`, `ansible-galaxy collection
    # install`'s own way of shipping roles, distinct from a plain Galaxy
    # role install) - entirely unimplemented before: resolve_role_dir only
    # ever looked under a playbook's own roles:/ directory, so any
    # collection-shipped role failed outright ("Role not found"). Real
    # Ansible resolves this by searching each configured collections path
    # for `ansible_collections/<namespace>/<collection>/roles/<role>` -
    # mirrored here against the same locations real Ansible checks:
    # ANSIBLE_COLLECTIONS_PATH (colon-separated, like ANSIBLE_ROLES_PATH),
    # a playbook-adjacent collections/ dir, ./collections relative to cwd,
    # and the two real default install locations (~/.ansible/collections,
    # /usr/share/ansible/collections).
    #
    # A bare 2-dot name is required (namespace.collection.role) - fewer
    # dots is an ordinary bare/short role name, which must fall through to
    # the plain roles:/ search below unchanged.
    private def self.resolve_collection_role_dir(name : String, playbook_dir : String) : String?
      parts = name.split('.')
      return nil if parts.size < 3

      namespace = parts[0]
      collection = parts[1]
      role_name = parts[2..].join('.')
      relative = File.join("ansible_collections", namespace, collection, "roles", role_name)

      collections_paths(playbook_dir).each do |base|
        candidate = File.join(base, relative)
        return candidate if Dir.exists?(candidate)
      end

      nil
    end

    private def self.collections_paths(playbook_dir : String) : Array(String)
      paths = [] of String

      if env_path = ENV["ANSIBLE_COLLECTIONS_PATH"]? || ENV["ANSIBLE_COLLECTIONS_PATHS"]?
        paths.concat(env_path.split(':').reject(&.empty?))
      end

      paths << File.join(playbook_dir, "collections")
      paths << "collections"
      # Real Ansible's `~/.ansible/collections` default is a per-user
      # absolute path (the user's actual home directory), NOT a
      # path-relative-to-cwd starting with the literal character `~`.
      # Crystal's `File.expand_path` does NOT expand a leading `~` -
      # it treats `~` as a literal directory name and joins it to the
      # CWD, producing `/tmp/~/.ansible/collections` when the binary
      # is run from `/tmp` and silently finding nothing there. Real
      # bug surfaced live in round 24 role 2 (dev-sec.hardening
      # collection form): the FQCN `devsec.hardening.mysql_hardening`
      # was being looked up as a bare role name first (failing with
      # "Role not found: ... (looked under ./roles/... and roles/...)")
      # because the collection path lookup silently never found
      # `~/.ansible/collections` for any CWD other than `$HOME`. Same
      # tilde-expansion bug already fixed in
      # `plugin_helpers/mysql_connection.cr#resolve_option_file_path`
      # (KNOWN_MISSING.md 0.9.346) and in `BasePlugin#expand_tilde`
      # (used by every plugin's path-type arg) - mirror the
      # System::User-home-directory + ENV["HOME"] fallback here too.
      paths << expand_home_path("~/.ansible/collections")
      paths << "/usr/share/ansible/collections"

      paths
    end

    # Same logic as `BasePlugin#expand_tilde` and
    # `plugin_helpers/mysql_connection.cr#resolve_option_file_path` -
    # a leading `~` resolves to the current user's home directory
    # (via `System::User` first, falling back to `ENV["HOME"]`),
    # otherwise the path is returned unchanged. Used for the
    # `~/.ansible/collections` default in `collections_paths` above.
    private def self.expand_home_path(path : String) : String
      return path unless path.starts_with?('~')

      rest = path[1..]
      username, _, remainder = rest.partition('/')
      home = if username.empty?
               System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory) || ENV["HOME"]?
             else
               System::User.find_by?(name: username).try(&.home_directory)
             end
      return path unless home
      remainder.empty? ? home : File.join(home, remainder)
    end

    private def self.existing_dir(path : String) : String?
      Dir.exists?(path) ? path : nil
    end

    # Public: TaskExecutor#execute_include_vars loads the same shape of
    # YAML vars file that roles do, and must parse it identically
    # (including Vault decryption of individual values).
    def self.load_vars_file(path : String) : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      return result unless File.exists?(path)

      yaml = YAML.parse(Vault.maybe_decrypt(File.read(path)))
      if hash = yaml.as_h?
        hash.each { |key, value| result[key.to_s] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value)) }
      end

      result
    end

    # Loads a role's defaults/ or vars/ - real Ansible supports EITHER a
    # single `main.yml` file OR a `main/` directory of multiple `*.yml`
    # files (same convention `tasks/main/` uses), merged together in
    # alphabetical filename order (later files win on a key collision -
    # matching real Ansible's own `main/` directory loading, which reads
    # files in sorted order and merges each into the accumulated dict).
    # Only ONE of the two forms is ever present for a given role.
    # Real bug found benchmarking kyl191.openvpn (round 160): its own
    # `defaults/main/openvpn.yml` (no `defaults/main.yml` at all) was
    # never read - `load_vars_file` alone always looked for exactly
    # `defaults/main.yml`, silently returning an empty hash for a role
    # using the directory form - every one of its own defaults
    # (`openvpn_server_network`, `openvpn_server_ipv6_network`, ...)
    # came back undefined, tripping the role's own "fail if both
    # tunnel networks are disabled" validation check that real Ansible
    # never reaches (both are non-empty by default).
    def self.find_main_file(dir : String) : String?
      # Real Ansible's loader accepts .yml/.yaml/.json interchangeably for
      # every main-file lookup. Only main.yml was checked before, so a
      # role shipping defaults/main.YAML (buluma.ara_api does exactly
      # that - every defaults var then undefined, first observed as
      # `'ara_api_root_dir' is undefined` while real ansible resolved it
      # fine, round 190) silently loaded an EMPTY defaults hash.
      %w[yml yaml json].each do |ext|
        candidate = File.join(dir, "main.#{ext}")
        return candidate if File.exists?(candidate)
      end
      nil
    end

    def self.load_vars_file_main(dir : String) : Hash(String, JSON::Any)
      if found = find_main_file(dir)
        return load_vars_file(found)
      end

      main_dir = File.join(dir, "main")
      return Hash(String, JSON::Any).new unless Dir.exists?(main_dir)

      result = Hash(String, JSON::Any).new
      (Dir.glob(File.join(main_dir, "*.yml")) + Dir.glob(File.join(main_dir, "*.yaml")) + Dir.glob(File.join(main_dir, "*.json"))).sort.each do |path|
        load_vars_file(path).each { |key, value| result[key] = value }
      end
      result
    end

    # Real Ansible auto-inserts a "Validating arguments against arg spec"
    # task as the first task of any role that ships meta/argument_specs.yml
    # (verified against real ansible-playbook: exact banner text
    # "Validating arguments against arg spec 'main' - <short_description>"),
    # checking the role's effective vars against the "main" entry point's
    # declared options before any of the role's own tasks run. Only "main"
    # is synthesized here (the implicit entry point for a roles:/
    # include_role: without tasks_from: - the only form this codebase
    # supports for role invocation in the first place).
    private def self.load_argument_spec_validation_task(role_dir : String) : Task?
      spec_path = File.join(role_dir, "meta", "argument_specs.yml")
      return nil unless File.exists?(spec_path)

      yaml = YAML.parse(Vault.maybe_decrypt(File.read(spec_path)))
      main_spec = yaml["argument_specs"]?.try(&.["main"]?)
      return nil unless main_spec

      options_yaml = main_spec["options"]?.try(&.as_h?)
      return nil unless options_yaml

      options = Hash(String, JSON::Any).new
      options_yaml.each { |key, value| options[key.to_s] = Vault.yaml_value_to_json(value) }

      short_description = main_spec["short_description"]?.try(&.as_s?)
      name = short_description ? "Validating arguments against arg spec 'main' - #{short_description}" : "Validating arguments against arg spec 'main'"

      task = Task.new(name, "_validate_argument_spec")
      task.validate_argument_spec_options = options
      task
    end

    private def self.load_tasks_file(path : String, play : Play, known_vars : Hash(String, JSON::Any)? = nil) : Array(Task)
      return [] of Task unless File.exists?(path)

      yaml = YAML.parse(Vault.maybe_decrypt(File.read(path)))
      return [] of Task unless yaml.as_a?

      PlaybookParser.parse_tasks(yaml.as_a, play, "task in #{path}", File.dirname(path), known_vars)
    end
  end
end
