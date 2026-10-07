require "yaml"
require "./unsafe_values"
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
    # same existence check for a task-level `import_role:`, which
    # Ansible resolves STATICALLY (before any task runs) exactly like a
    # play-level `roles:` entry or a meta/main.yml dependency already
    # does via #load_role's own RoleNotFoundError raise - previously
    # only those two call sites checked existence at all; a task-level
    # import_role: referencing a role never installed (buluma.revealmd's
    # own `import_role: name: buluma.service`, round 180) instead ran 5
    # of the role's OWN tasks first and only failed later at the runtime
    # `_include_role` dispatch, instead of refusing the whole playbook
    # up front the way Ansible does (rc=1, zero tasks run).
    # Process-wide parsed-YAML memo for role files. include_role: re-reads
    # and re-parses the SAME tasks/main.yml, handlers/main.yml, defaults/,
    # vars/ and meta/main.yml on EVERY invocation - once per loop item,
    # once per serial batch, once per repeated include - and YAML parsing
    # dominates that cost by far. The cache stores the parsed YAML::Any
    # tree; the per-invocation Task objects are still built FRESH by
    # parse_tasks on every call (the executor mutates tasks per
    # invocation - tags merge, role-context stamping, item binding - so
    # sharing Task objects would be the cross-invocation mutation hazard
    # the parallel-dispatch safety argument depends on NOT having).
    # Role files are static for the lifetime of a run, so there is no
    # invalidation; the cache is safe under cooperative scheduling (plain
    # hash insert, no yield point).
    @@parsed_yaml_cache = Hash(String, YAML::Any).new

    private def self.cached_yaml(path : String) : YAML::Any
      @@parsed_yaml_cache.fetch(path) do
        text = Vault.maybe_decrypt(File.read(path))
        UnsafeValues.mark_yaml_text(text)
        @@parsed_yaml_cache[path] = YAML.parse(text)
      end
    end

    # Role-file tasks carry their own source file + position map, the
    # way Ansible's task objects do - a task parsed from a role's
    # tasks/main.yml reports Origins against THAT file (live-verified vs
    # 2.19.11: an include_role: inside a role whose role name resolves
    # nowhere points its runtime error's Origin at
    # <role>/tasks/main.yml:<line>:<col> of the name value).
    private def self.cached_source_map(path : String) : YamlSourceMap
      @@source_map_cache.fetch(path) do
        @@source_map_cache[path] = YamlSourceMap.scan(Vault.maybe_decrypt(File.read(path)))
      end
    end

    @@source_map_cache = Hash(String, YamlSourceMap).new

    def self.role_exists?(name : String, playbook_dir : String) : Bool
      !resolve_role_dir(name, playbook_dir).nil?
    end

    # Whether a role's tasks/<tasks_from> file does not exist - public so
    # PlaybookParser can reproduce real's parse-time refusal of a STATIC
    # import_role: whose tasks_from: points nowhere (see
    # RoleTasksFromFileError's own comment). *tasks_from* is taken
    # literally, exactly as real builds the path (an explicit extension
    # is honored, a bare name gets ".yml"/".yaml"/".json" tried in that
    # order by #resolve_role_tasks_path).
    def self.role_tasks_file_missing?(name : String, playbook_dir : String, tasks_from : String) : Bool
      role_dir = resolve_role_dir(name, playbook_dir)
      return true unless role_dir
      !File.file?(resolve_role_tasks_path(role_dir, tasks_from))
    end

    # The role search path list exactly as ansible-core's
    # RoleDefinition._load_role_path builds and REPORTS it
    # (definition.py: "the role '<name>' was not found in <paths>"):
    # the playbook dir's own roles/ subtree first, then the configured
    # roles paths (ANSIBLE_ROLES_PATH or the ~/.ansible:/usr/share:/
    # /etc/ansible defaults), then the playbook dir itself. Live-verified
    # against 2.19.11: a missing role errors as "the role 'x' was not
    # found in /work/roles:/root/.ansible/roles:/usr/share/ansible/roles:
    # /etc/ansible/roles:/work". Display-only - resolve_role_dir above
    # keeps its own (superset) search order.
    def self.role_search_display(playbook_dir : String) : String
      basedir = File.expand_path(playbook_dir)
      paths = [File.join(basedir, "roles")]
      paths.concat(roles_paths)
      paths << basedir
      paths.join(":")
    end

    # Loads every entry in a play's `roles:` list (plus their meta/main.yml
    # dependencies, recursively), in order. Returns {tasks, handlers} to
    # prepend to the play - Ansible runs role tasks before the play's own
    # tasks: (pre_tasks:/post_tasks: aren't implemented).
    def self.load_roles(roles_yaml : Array(YAML::Any), play : Play, playbook_dir : String, source_map : YamlSourceMap? = nil, roles_prefix : String = "roles") : {Array(Task), Array(Task)}
      seen = Set(String).new
      tasks = [] of Task
      handlers = [] of Task

      roles_yaml.each_with_index do |entry, entry_index|
        # The entry's invocation vars carry their defining positions from
        # the playbook's own source map - real points a name-template
        # error inside a role PARAM at the playbook's `roles:` entry
        # (live-verified 2.19.11: `roles: [{role: e9, vars: {rp: ...}}]`
        # reports e9.yml's vars value position).
        name, entry_version, invocation_vars, invocation_tags, entry_when, invocation_origins, entry_timeout = parse_role_entry(entry, play.source_file, source_map, "#{roles_prefix}/#{entry_index}")
        before_count = tasks.size
        load_role(name, invocation_vars, invocation_tags, play, playbook_dir, seen, tasks, handlers, play_scope: true, role_version: entry_version, role_when: entry_when, invocation_var_origins: invocation_origins, role_timeout: entry_timeout)
        apply_role_when(tasks, before_count, entry_when)
      end

      {tasks, handlers}
    end

    # Loads a single role by name (plus its meta/main.yml dependencies) -
    # used by TaskExecutor#execute_include_role for include_role:, the
    # dynamic (execution-time) counterpart to a static roles: entry. Each
    # call gets its own fresh "seen" set, so - matching include_role's
    # allow_duplicates: true default - repeated include_role calls for the
    # same role name each load it again rather than being silently
    # deduplicated the way a role listed twice under roles: would be.
    # allow_duplicates: false on the include itself isn't honored (dedup
    # only happens within a single call's own meta dependency chain).
    def self.load_single_role(name : String, invocation_vars : Hash(String, JSON::Any), invocation_tags : Array(String), play : Play, playbook_dir : String, tasks_from : String? = nil, parent_names : Array(String) = [] of String, parent_paths : Array(String) = [] of String, parent_defaults : Hash(String, JSON::Any) = Hash(String, JSON::Any).new, parent_default_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new, invocation_var_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new) : {Array(Task), Array(Task)}
      seen = Set(String).new
      tasks = [] of Task
      handlers = [] of Task

      load_role(name, invocation_vars, invocation_tags, play, playbook_dir, seen, tasks, handlers, tasks_from, parent_names, parent_paths, parent_defaults, parent_default_origins, invocation_var_origins)

      {tasks, handlers}
    end

    # A roles: entry is either a bare string ("common") or a mapping with
    # role:/name: (+ optional vars:/tags:, and Ansible also treats any
    # other top-level key as a role var - `roles: [{role: app, port: 8080}]`).
    private def self.parse_role_entry(entry : YAML::Any, origin_file : String? = nil, source_map : YamlSourceMap? = nil, path_prefix : String? = nil) : {String, String?, Hash(String, JSON::Any), Array(String), String?, Hash(String, VarOrigin), {Int64?, String?}}
      if bare_name = entry.as_s?
        return {bare_name, nil, Hash(String, JSON::Any).new, [] of String, nil, Hash(String, VarOrigin).new, {nil, nil}}
      end

      origins = Hash(String, VarOrigin).new

      hash = entry.as_h
      # `src:` is Ansible's own `RoleRequirement` key - the SAME
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
      # v1.0.9}]`), which Ansible resolves and installs fine.
      name = (hash["role"]? || hash["name"]? || hash["src"]?).try(&.as_s)
      raise "Role entry missing 'role' or 'name'" unless name

      vars = Hash(String, JSON::Any).new
      if vars_yaml = hash["vars"]?.try(&.as_h?)
        vars_yaml.each do |key, value|
          key_str = key.to_s
          vars[key_str] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))
          if origin = entry_var_origin(origin_file, source_map, path_prefix, key_str, "vars")
            origins[key_str] = origin
          end
        end
      end

      # `version`/`scm` are the other two `RoleRequirement` galaxy-source
      # keys that travel alongside `src:` - dependency-RESOLUTION
      # metadata (which tag/branch/protocol to fetch from), not role
      # vars, so they must be excluded here the same way `role`/`name`
      # already are (a `version: v1.0.9` var leaking into the role's own
      # vars context, e.g. via `{{ version }}`, would be a real
      # divergence from what Ansible - which never exposes these
      # as vars either - provides). `version` is still captured (below)
      # for the dependency-dedup key: Ansible treats two dependency
      # declarations differing ONLY in their `version:` pin as two
      # distinct invocations and runs both (verified live,
      # andrewrothstein.kafka-consumer's v1.0.13-via-kafka vs
      # v1.0.12-via-openjdk unarchive-deps double run).
      reserved = {"role", "name", "src", "version", "scm", "vars", "tags", "when", "timeout"}
      version = hash["version"]?.try(&.to_s)
      hash.each do |key, value|
        key_str = key.to_s
        next if reserved.includes?(key_str)
        vars[key_str] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value))
        if origin = entry_var_origin(origin_file, source_map, path_prefix, key_str, nil)
          origins[key_str] = origin
        end
      end

      tags = hash["tags"]?.try(&.as_a?).try(&.map(&.as_s)) || [] of String

      # `when:` on a roles: entry or a meta/main.yml dependency is
      # Ansible's own RoleRequirement field - it does NOT gate the role
      # "as a whole" the way it might look; Ansible statically
      # resolves the role's tasks and combines this when: (parent
      # PREPENDED) onto EVERY one of them, same as import_role:'s own
      # when: propagation (see execute_include_role's identical fix).
      # Found via Graylog2.graylog's own `meta/main.yml` dependency on
      # lean_delivery.java (`when: graylog_install_java`, undefined -
      # Ansible skips the whole dependency's task tree; this
      # engine used to load and run it unconditionally, since neither
      # parse_role_entry nor load_role/load_meta_dependencies had any
      # notion of a `when:` on a role entry at all - it silently
      # dropped through as a role VAR named "when" instead of a gate.
      role_when = hash["when"]?.try { |cond| PlaybookParser.condition_to_string(cond) }

      # `timeout:` on a roles: entry is a valid TASK keyword in real
      # ansible-core (live-verified vs 2.19.11: `roles: [- role: r,
      # timeout: 2]` fails every role task that runs past it) - a
      # keyword, NOT a role var, so it is reserved out of the vars bag
      # and applied to the role's tasks through load_role's ambient
      # inheritance (precedence task > block > role entry > play).
      role_timeout = PlaybookParser.parse_timeout_value(hash["timeout"]?)

      {name, version, vars, tags, role_when, origins, role_timeout}
    end

    # One roles:/dependency entry var's defining position - nil when no
    # source map is available (the origin block for such a var is then
    # omitted, never mislabeled).
    private def self.entry_var_origin(origin_file : String?, source_map : YamlSourceMap?, path_prefix : String?, key : String, sub : String?) : VarOrigin?
      return nil unless source_map && path_prefix && origin_file
      path = sub ? "#{path_prefix}/#{sub}/#{key}" : "#{path_prefix}/#{key}"
      return nil unless pos = source_map.at?(path)
      FileVarOrigin.new(File.expand_path(origin_file), pos[0], pos[1])
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
      # Origins for parent_defaults (see Task#role_default_origins) -
      # threaded through the include_role/dependency chain exactly like
      # the values themselves.
      parent_default_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new,
      # Origins for invocation_vars.
      invocation_var_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new,
      # When non-nil, receives this role's merged defaults origins
      # (mirroring the `defaults` return value) - load_meta_dependencies
      # collects them alongside the dependency defaults.
      default_origins_out : Hash(String, VarOrigin)? = nil,
      # Whether this role's own defaults/vars join the PLAY-WIDE layers
      # every role can see (Play#all_role_defaults/#all_role_vars). True
      # for a static `roles:` entry and its meta dependencies, which
      # Ansible loads at play setup; FALSE for include_role:, whose
      # vars/defaults Ansible keeps scoped to that inclusion unless
      # it is `public: true` - contributing them here would expose them
      # to every later task in the play instead.
      play_scope : Bool = false,
      # The dependency entry's `version:` pin, when declared - part of the
      # invocation identity #role_dedup_key dedupes on (not a role var,
      # matching Ansible, which never exposes it as one).
      role_version : String? = nil,
      role_when : String? = nil,
      # The roles:-entry's own `timeout:` keyword value {int, expr} -
      # {nil, nil} when the entry set none (the default for include_role:,
      # whose invocation has no such keyword in this engine).
      role_timeout : {Int64?, String?} = {nil, nil},
    )
      role_dir = resolve_role_dir(name, playbook_dir)
      unless role_dir
        raise RoleNotFoundError.new("the role '#{name}' was not found in #{role_search_display(playbook_dir)}")
      end

      # An already-loaded role contributes no defaults a second time -
      # its tasks (and their defaults) are already in the play. The key
      # is the full invocation identity, NOT just the bare role name (see
      # #role_dedup_key) - found via andrewrothstein.kafka-consumer's
      # dependency graph, which reaches andrewrothstein.unarchive-deps
      # twice (via andrewrothstein.kafka AND via andrewrothstein.openjdk)
      # with two different `version:` pins; Ansible (verified live
      # against ansible-core 2.19.11, both with this exact role graph and
      # with synthetic same-name/different-params graphs) runs it twice,
      # while deduping by name alone silently dropped the second run.
      dedup_key = role_dedup_key(name, role_version, invocation_vars, invocation_tags, role_when)
      return Hash(String, JSON::Any).new if !meta_allows_duplicates?(role_dir) && seen.includes?(dedup_key)
      seen.add(dedup_key)
      # Ansible's `role_path` magic var is always an ABSOLUTE path -
      # resolve_role_dir's own search dirs can be relative (a bare "roles"
      # search root, or a relative ANSIBLE_ROLES_PATH entry), and that
      # relative-ness was leaking straight into task.role_path below.
      # Found benchmarking linux-system-roles.timesync's own `paths:
      # ["{{ role_path }}/vars"]` first_found idiom (Ansible's own
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
      # extended further), matching Ansible: a dependency isn't
      # "nested inside" the declaring role's own tasks the way an
      # include_role: call is.
      dependency_default_origins = Hash(String, VarOrigin).new
      dependency_defaults = load_meta_dependencies(role_dir, play, playbook_dir, seen, tasks, handlers, parent_names, parent_paths, parent_defaults, play_scope, parent_default_origins, dependency_default_origins)

      defaults = load_vars_file_main(File.join(role_dir, "defaults"))
      # Ansible keeps a role's defaults visible for the rest of the
      # PLAY once that role has run, not just for tasks physically inside
      # that role's own files - a role invoked via `include_role:` from
      # inside another role's tasks (prometheus.prometheus's own `_common`
      # shared-logic role, invoked from every exporter role's own
      # configure.yml) still needs to see the CALLING role's defaults.
      # `parent_defaults` is the accumulated chain from every ancestor
      # role that led here (root-first merge order, so a NEARER ancestor's
      # default wins over a more distant one on a naming collision -
      # matches Ansible's own "later-loaded role wins" precedence for
      # defaults); this role's own defaults win over all of them. Found
      # via that exact `_common` scenario: node_exporter's own `node_
      # exporter_textfile_dir` default (defaults/main.yml) went undefined
      # the moment its own `node_exporter.service.j2` template got
      # rendered from within _common's included tasks, even though
      # Ansible keeps it in scope - `task.role_defaults` was previously
      # always just THIS role's own defaults, discarding the whole
      # ancestor chain.
      #
      # A meta/main.yml DEPENDENCY's own defaults are in scope for the
      # role that declares it, too - Ansible loads a dependency
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
      # precedence than this role's own defaults, matching
      # Ansible's own dependency-then-self load order.
      defaults = parent_defaults.merge(dependency_defaults).merge(defaults)
      # Origins mirror the value merge above exactly, so a lookup always
      # answers for the value that actually wins (see
      # Task#role_default_origins).
      defaults_origins = parent_default_origins.merge(dependency_default_origins).merge(load_vars_file_origins_main(File.join(role_dir, "defaults")))
      own_vars = load_vars_file_main(File.join(role_dir, "vars"))
      own_var_origins = load_vars_file_origins_main(File.join(role_dir, "vars"))
      role_vars = own_vars.dup
      role_var_origins = own_var_origins.dup
      invocation_vars.each do |key, value|
        role_vars[key] = value
        # The winning value's origin travels with it; an invocation var
        # with no known origin (no source map) erases the vars/main.yml
        # origin it overrides, matching the value it replaces.
        if (origin = invocation_var_origins[key]?)
          role_var_origins[key] = origin
        else
          role_var_origins.delete(key)
        end
      end

      # Contribute to the play-wide layers every role can see - see
      # Play#all_role_defaults for why Ansible makes these visible
      # to roles that ran EARLIER too. Assigned in load order, so a
      # later role wins a name collision, which is what Ansible
      # answers outside any role (verified: post_tasks: sees the LAST
      # role's value for a name two roles both define).
      #
      # Uses `own_vars`/a freshly-reloaded `own_defaults` here, NOT
      # `role_vars`/`defaults` (which have `invocation_vars`/ancestor
      # defaults already merged in) - a role's own vars/main.yml and
      # defaults/main.yml genuinely stay visible play-wide, but a
      # PER-INVOCATION override (a `vars:` on this one `roles:` entry, or
      # a `meta/main.yml` dependency's own inline params, e.g.
      # `- role: dep, some_var: false`) is scoped to that ONE invocation
      # only and must not leak into every later task in the play. Found
      # via brunobenchimol.certbot_dns's own `meta/main.yml` dependency
      # (`- role: geerlingguy.certbot, certbot_auto_renew: false`,
      # overriding that value for the dependency's OWN tasks only): the
      # declaring role's own LATER task (`when: not certbot_auto_renew`,
      # relying on ITS OWN `certbot_auto_renew: true` default) saw the
      # dependency's overridden `false` instead, running when
      # Ansible correctly skipped it.
      if play_scope
        own_defaults = load_vars_file_main(File.join(role_dir, "defaults"))
        own_defaults.each { |key, value| play.all_role_defaults[key] = value }
        load_vars_file_origins_main(File.join(role_dir, "defaults")).each { |key, origin| play.all_role_default_origins[key] = origin }
        own_vars.each { |key, value| play.all_role_vars[key] = value }
        own_var_origins.each { |key, origin| play.all_role_var_origins[key] = origin }
      end

      files_dir = existing_dir(File.join(role_dir, "files"))
      templates_dir = existing_dir(File.join(role_dir, "templates"))
      vars_dir = existing_dir(File.join(role_dir, "vars"))

      # Known at parse time, before facts gathering - Ansible's own
      # constraint for what import_tasks:'s own file path may reference
      # (see try_parse_import_tasks in playbook_parser.cr). role_vars
      # wins over defaults, matching normal precedence.
      #
      # role_path is a magic var Ansible always has available here
      # (it's just this role's own directory, known as soon as parsing
      # begins) - found via infOpen.openjdk-jre's own `import_tasks:
      # "{{ role_path }}/tasks/manage_variables.yml"`, a real, if
      # unusual, pattern for a role to make its own static-import
      # target path independent of wherever the role happens to be
      # vendored under. Without it, that path template raised
      # StaticImportUndefinedError ("'role_path' is undefined") and
      # refused to even start the play, where ansible-core
      # resolves it immediately and moves on.
      known_vars = defaults.merge(role_vars)
      known_vars["role_path"] = JSON::Any.new(role_dir)
      # tasks_from: loads tasks/<name>.yml instead of tasks/main.yml -
      # handlers/defaults/vars still always come from their normal
      # main.yml locations regardless (matching Ansible: only the
      # entry-point TASKS file changes).
      # Ansible accepts tasks_from: with OR without the extension
      # (prometheus.prometheus's own roles write it both ways across
      # different calls - `tasks_from: install.yml` as well as bare
      # names elsewhere) - append .yml only when it's not already there.
      tasks_path = resolve_role_tasks_path(role_dir, tasks_from)
      # The roles:-entry's own `timeout:` (a real task keyword in real
      # ansible-core) becomes the ambient default every task parsed
      # below inherits - the same save/set/parse/restore pattern
      # PlaybookParser#parse_block_task uses for block-level keywords,
      # so precedence stays task > block > role entry > play.
      saved_task_timeout = play.task_timeout
      saved_task_timeout_expr = play.task_timeout_expr
      play.task_timeout = role_timeout[0] if role_timeout[0]
      play.task_timeout_expr = role_timeout[1] if role_timeout[1]
      begin
        role_tasks = load_tasks_file(tasks_path, play, known_vars, role_dir)
        role_handlers = load_tasks_file(find_main_file(File.join(role_dir, "handlers")) || File.join(role_dir, "handlers", "main.yml"), play, known_vars, role_dir)
      ensure
        play.task_timeout = saved_task_timeout
        play.task_timeout_expr = saved_task_timeout_expr
      end

      # The argument-spec "Validating arguments..." task only applies to
      # the role's own default ("main") entry point, not an arbitrary
      # tasks_from: file.
      if !tasks_from && (validation_task = load_argument_spec_validation_task(role_dir))
        role_tasks.unshift(validation_task)
      end

      (role_tasks + role_handlers).each do |task|
        task.role_defaults = defaults
        task.role_vars = role_vars
        task.role_default_origins = defaults_origins
        task.role_var_origins = role_var_origins
        task.role_files_dir = files_dir
        task.role_templates_dir = templates_dir
        task.role_vars_dir = vars_dir
        # include_role_dir must stay anchored to the ORIGINAL playbook's
        # own directory - Ansible's role search paths are always
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
        # ...and into the inherited context as well: a roles: entry's
        # tags (and an import_role:'s, passed through the same path) are
        # a block-level push in Ansible, so they reach not just these
        # tasks but anything THEY include at run time - an
        # include_tasks: statement inside the role passes its inherited
        # context down to the file it loads (live-verified vs 2.19.11:
        # `roles: [{role: r, tags: [rtag]}]` where r include_tasks:'s an
        # untagged file - `--tags rtag` runs the inner task in real
        # Ansible; same for an import_role: with `tags: [itag]`).
        task.inherited_tags = (task.inherited_tags + invocation_tags).uniq
      end

      # A task inside a role's block:/rescue:/always: belongs to that role
      # just as much as a top-level one - real's get_name() shows
      # "role : name" for a NAMED block child in --list-tasks (and the
      # runtime executor's propagate_role_context stamps the same fields
      # on its way through blocks, so this parse-time stamping only makes
      # the listing-time view agree with what run time already produced).
      (role_tasks + role_handlers).each { |task| stamp_role_into_blocks(task, name, role_dir, parent_names, parent_paths, collection_name) }

      tasks.concat(role_tasks)
      handlers.concat(role_handlers)

      # Returned so a DECLARING role can pick these up as its own
      # dependency defaults (see the `dependency_defaults` merge above).
      if out = default_origins_out
        defaults_origins.each { |key, origin| out[key] = origin }
      end
      defaults
    end

    # Copies the role binding into a task's nested block/rescue/always
    # children, recursively - the per-task stamp loop above only reaches
    # each role file's TOP-LEVEL tasks, so a named task inside a role's
    # block listed without its "role : " prefix in --list-tasks (real
    # flattens blocks in the listing and prefixes the children).
    private def self.stamp_role_into_blocks(task : Task, name : String, role_dir : String, parent_names : Array(String), parent_paths : Array(String), collection_name : String?) : Nil
      task.block_tasks.try &.each do |nested|
        stamp_role_task(nested, name, role_dir, parent_names, parent_paths, collection_name)
        stamp_role_into_blocks(nested, name, role_dir, parent_names, parent_paths, collection_name)
      end
      task.rescue_tasks.try &.each do |nested|
        stamp_role_task(nested, name, role_dir, parent_names, parent_paths, collection_name)
        stamp_role_into_blocks(nested, name, role_dir, parent_names, parent_paths, collection_name)
      end
      task.always_tasks.try &.each do |nested|
        stamp_role_task(nested, name, role_dir, parent_names, parent_paths, collection_name)
        stamp_role_into_blocks(nested, name, role_dir, parent_names, parent_paths, collection_name)
      end
    end

    private def self.stamp_role_task(task : Task, name : String, role_dir : String, parent_names : Array(String), parent_paths : Array(String), collection_name : String?) : Nil
      task.role_name = name
      task.role_path = role_dir
      task.role_parent_names = parent_names
      task.role_parent_paths = parent_paths
      task.ansible_collection_name = collection_name
    end

    # tasks_from: loads tasks/<name>.yml instead of tasks/main.yml -
    # handlers/defaults/vars still always come from their normal main.yml
    # locations regardless (matching Ansible: only the entry-point
    # TASKS file changes). Ansible accepts tasks_from: with OR
    # without the extension (prometheus.prometheus's own roles write it
    # both ways across different calls - `tasks_from: install.yml` as
    # well as bare names elsewhere) - append .yml only when it's not
    # already there.
    private def self.resolve_role_tasks_path(role_dir : String, tasks_from : String?) : String
      return find_main_file(File.join(role_dir, "tasks")) || File.join(role_dir, "tasks", "main.yml") unless tasks_from
      return File.join(role_dir, "tasks", tasks_from) if tasks_from.ends_with?(".yml") || tasks_from.ends_with?(".yaml") || tasks_from.ends_with?(".json")

      # Ansible resolves a bare tasks_from: name against ANY of its
      # accepted extensions.
      ext = %w[yml yaml json].find { |e| File.exists?(File.join(role_dir, "tasks", "#{tasks_from}.#{e}")) }
      File.join(role_dir, "tasks", "#{tasks_from}.#{ext || "yml"}")
    end

    # Returns the accumulated defaults of every dependency loaded (later
    # dependencies winning over earlier ones on a name collision, matching
    # Ansible's load order), for the declaring role to merge under
    # its own - see `load_role`'s `dependency_defaults` comment.
    private def self.load_meta_dependencies(role_dir : String, play : Play, playbook_dir : String, seen : Set(String), tasks : Array(Task), handlers : Array(Task), parent_names : Array(String) = [] of String, parent_paths : Array(String) = [] of String, parent_defaults : Hash(String, JSON::Any) = Hash(String, JSON::Any).new, play_scope : Bool = false, parent_default_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new, collected_origins : Hash(String, VarOrigin) = Hash(String, VarOrigin).new) : Hash(String, JSON::Any)
      collected = Hash(String, JSON::Any).new
      meta_path = find_main_file(File.join(role_dir, "meta")) || File.join(role_dir, "meta", "main.yml")
      return collected unless File.exists?(meta_path)

      meta_yaml = cached_yaml(meta_path)
      deps = meta_yaml["dependencies"]?.try(&.as_a?)
      return collected unless deps

      deps.each_with_index do |dep, dep_index|
        dep_name, dep_version, dep_vars, dep_tags, dep_when, dep_origins = parse_role_entry(dep, meta_path, cached_source_map(meta_path), "dependencies/#{dep_index}")
        before_count = tasks.size
        dep_default_origins = Hash(String, VarOrigin).new
        dep_defaults = load_role(dep_name, dep_vars, dep_tags, play, playbook_dir, seen, tasks, handlers, nil, parent_names, parent_paths, parent_defaults, parent_default_origins, dep_origins, play_scope: play_scope, role_version: dep_version, role_when: dep_when, default_origins_out: dep_default_origins)
        apply_role_when(tasks, before_count, dep_when)
        # Origins mirror the value merge below exactly: a key the earlier
        # dependency already provided keeps ITS origin; a key this
        # dependency newly provides takes this dependency's (or none).
        dep_defaults.each_key do |key|
          next if collected.has_key?(key)
          if dep_default_origins.has_key?(key)
            collected_origins[key] = dep_default_origins[key]
          else
            collected_origins.delete(key)
          end
        end
        collected.merge!(dep_defaults)
      end

      collected
    end

    # The dedup key for one role invocation: role name + its `version:`
    # pin + its inline vars + tags + when. Ansible (ansible-core
    # 2.19.11, verified live with synthetic role graphs) deduplicates a
    # meta/dependency invocation only when this whole identity matches -
    # two declarations of the same role name that differ in ANY of these
    # both run, no matter how many times the role is reachable in one
    # dependency graph - while a genuinely identical pair still collapses
    # to a single run.
    private def self.role_dedup_key(name : String, version : String?, vars : Hash(String, JSON::Any), tags : Array(String), role_when : String?) : String
      String.build do |io|
        io << name << "|version=" << (version || "")
        io << "|vars=" << vars.keys.sort!.map { |k| "#{k}=#{vars[k]}" }.join(",")
        io << "|tags=" << tags.sort.join(",")
        io << "|when=" << (role_when || "")
      end
    end

    # A shared dependency's own meta/main.yml `allow_duplicates: true` is
    # Ansible's escape hatch to opt out of dependency deduplication
    # entirely: with it, even two IDENTICAL invocations of the role both
    # run (probe-verified); without it (the default), only non-identical
    # invocations run more than once.
    private def self.meta_allows_duplicates?(role_dir : String) : Bool
      meta_path = find_main_file(File.join(role_dir, "meta")) || File.join(role_dir, "meta", "main.yml")
      return false unless File.exists?(meta_path)

      flag = cached_yaml(meta_path)["allow_duplicates"]?
      (flag.try(&.as_bool?) || false)
    end

    # Prepends *role_when* (parent-first, matching import_role:'s own
    # when: propagation order - see execute_include_role's identical
    # fix) onto every task newly appended to *tasks* since *before_count*
    # - i.e. every task this one role entry (and its own meta
    # dependencies, loaded recursively inside the same call) contributed.
    # A no-op when role_when is nil (the common case: no when: on this
    # entry at all).
    private def self.apply_role_when(tasks : Array(Task), before_count : Int32, role_when : String?) : Nil
      return unless role_when
      (before_count...tasks.size).each do |i|
        task = tasks[i]
        task.when_condition = task.when_condition ? "(#{role_when}) and (#{task.when_condition})" : role_when
      end
    end

    private def self.resolve_role_dir(name : String, playbook_dir : String) : String?
      # A role name containing a path separator (absolute, or relative like
      # "../common_roles/foo") is used directly, matching Ansible -
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

    # Ansible's role search also checks `ANSIBLE_ROLES_PATH` (colon-
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
    # collection-shipped role failed outright ("Role not found").
    # Ansible resolves this by searching each configured collections path
    # for `ansible_collections/<namespace>/<collection>/roles/<role>` -
    # mirrored here against the same locations Ansible checks:
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

    # Public: PluginManager's connection-plugin resolution (fix "the
    # connection plugin 'X' was not found") searches the same controller
    # collection locations for `plugins/connection/<name>.py`.
    def self.collections_paths(playbook_dir : String = ".") : Array(String)
      paths = [] of String

      if env_path = ENV["ANSIBLE_COLLECTIONS_PATH"]? || ENV["ANSIBLE_COLLECTIONS_PATHS"]?
        paths.concat(env_path.split(':').reject(&.empty?))
      end

      paths << File.join(playbook_dir, "collections")
      paths << "collections"
      # Ansible's `~/.ansible/collections` default is a per-user
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
      # ENV["HOME"] + System::User-home-directory fallback here too.
      paths << expand_home_path("~/.ansible/collections")
      paths << "/usr/share/ansible/collections"

      paths
    end

    # Same logic as `BasePlugin#expand_tilde` and
    # `plugin_helpers/mysql_connection.cr#resolve_option_file_path` -
    # a leading `~` resolves to the current user's home directory
    # (via `ENV["HOME"]` first, falling back to the `System::User`
    # passwd entry), otherwise the path is returned unchanged. Used for
    # the `~/.ansible/collections` default in `collections_paths` above.
    #
    # `ENV["HOME"]` MUST come first: Ansible resolves `~` with
    # `os.path.expanduser`, which consults `$HOME` before the passwd
    # entry, and the two disagree whenever they are out of sync. This
    # order was the reverse of the other two copies, so the role-search-
    # path error message named the passwd entry's home (e.g. /root) while
    # the plugin's own tilde expansion named `$HOME` - visible as a CI
    # failure where the runner's `HOME=/github/home` disagrees with the
    # `root` passwd entry.
    private def self.expand_home_path(path : String) : String
      return path unless path.starts_with?('~')

      rest = path[1..]
      username, _, remainder = rest.partition('/')
      home = if username.empty?
               ENV["HOME"]? || System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory)
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

      yaml = cached_yaml(path)
      if hash = yaml.as_h?
        hash.each { |key, value| result[key.to_s] = Vault.maybe_decrypt_json(Vault.yaml_value_to_json(value)) }
      end

      result
    end

    # Loads a role's defaults/ or vars/ - Ansible supports EITHER a
    # single `main.yml` file OR a `main/` directory of multiple `*.yml`
    # files (same convention `tasks/main/` uses), merged together in
    # alphabetical filename order (later files win on a key collision -
    # matching Ansible's own `main/` directory loading, which reads
    # files in sorted order and merges each into the accumulated dict).
    # Only ONE of the two forms is ever present for a given role.
    # Real bug found benchmarking kyl191.openvpn (round 160): its own
    # `defaults/main/openvpn.yml` (no `defaults/main.yml` at all) was
    # never read - `load_vars_file` alone always looked for exactly
    # `defaults/main.yml`, silently returning an empty hash for a role
    # using the directory form - every one of its own defaults
    # (`openvpn_server_network`, `openvpn_server_ipv6_network`, ...)
    # came back undefined, tripping the role's own "fail if both
    # tunnel networks are disabled" validation check that Ansible
    # never reaches (both are non-empty by default).
    def self.find_main_file(dir : String) : String?
      # Ansible's loader accepts .yml/.yaml/.json interchangeably for
      # every main-file lookup. Only main.yml was checked before, so a
      # role shipping defaults/main.YAML (buluma.ara_api does exactly
      # that - every defaults var then undefined, first observed as
      # `'ara_api_root_dir' is undefined` while Ansible resolved it
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

    # Origins for #load_vars_file_main's result - same file discovery,
    # same merge order, so a lookup answers for the value that wins.
    private def self.load_vars_file_origins_main(dir : String) : Hash(String, VarOrigin)
      if found = find_main_file(dir)
        return vars_file_origins(found)
      end

      main_dir = File.join(dir, "main")
      return Hash(String, VarOrigin).new unless Dir.exists?(main_dir)

      result = Hash(String, VarOrigin).new
      (Dir.glob(File.join(main_dir, "*.yml")) + Dir.glob(File.join(main_dir, "*.yaml")) + Dir.glob(File.join(main_dir, "*.json"))).sort.each do |path|
        vars_file_origins(path).each { |key, origin| result[key] = origin }
      end
      result
    end

    # Origins for one vars-style YAML file's top-level keys (the keys come
    # from the same cached_yaml parse load_vars_file uses).
    private def self.vars_file_origins(path : String) : Hash(String, VarOrigin)
      keys = cached_yaml(path).as_h?.try(&.keys.map(&.to_s)) || [] of String
      VarOrigin.vars_file_origins(path, keys)
    rescue
      Hash(String, VarOrigin).new
    end

    # Ansible auto-inserts a "Validating arguments against arg spec"
    # task as the first task of any role that ships meta/argument_specs.yml
    # (verified against ansible-playbook: exact banner text
    # "Validating arguments against arg spec 'main' - <short_description>"),
    # checking the role's effective vars against the "main" entry point's
    # declared options before any of the role's own tasks run. Only "main"
    # is synthesized here (the implicit entry point for a roles:/
    # include_role: without tasks_from: - the only form this codebase
    # supports for role invocation in the first place).
    private def self.load_argument_spec_validation_task(role_dir : String) : Task?
      spec_path = File.join(role_dir, "meta", "argument_specs.yml")
      return nil unless File.exists?(spec_path)

      yaml = cached_yaml(spec_path)
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

    private def self.load_tasks_file(path : String, play : Play, known_vars : Hash(String, JSON::Any)? = nil, role_dir : String? = nil) : Array(Task)
      return [] of Task unless File.exists?(path)

      yaml = cached_yaml(path)
      return [] of Task unless yaml.as_a?

      # role_dir is this role's own root - PythonModuleRunner's role
      # `library/` search root, threaded through so the parse-time
      # unimplemented-module hard-stop finds a role-private module
      # source exactly where the executor later will.
      PlaybookParser.parse_tasks(yaml.as_a, play, "task in #{path}", File.dirname(path), known_vars, role_dir, nil, path, cached_source_map(path))
    end
  end
end
