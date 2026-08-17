require "yaml"
require "./loop_resolver"
require "./role_loader"
require "./vault"
require "./variable_substitutor"

module CrystalPlay
  # Represents a single task in a playbook
  class Task
    property name : String
    property module_name : String
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    # environment: - per-task env vars (real Ansible keyword). Raw,
    # unsubstituted string values, same convention as `params` - the
    # executor substitutes them at run time and forwards the result to
    # the plugin, which applies them around its own shelled-out commands.
    property environment : Hash(String, String)?
    property when_condition : String?
    property register : String?
    property notify : Array(String)?
    property listen : String?
    property ignore_errors : Bool
    property check_mode : Bool?
    property diff_mode : Bool?
    property become : Bool
    # Raw `{{ ... }}` text when become: is a templated expression rather
    # than a literal boolean (ansible-community.ansible-vault's own
    # `become: "{{ vault_privileged_install }}"`, defaulting false).
    # `become` above still holds a best-effort parse-time guess (used as
    # a fallback if this can't be rendered for some reason), but the
    # executor re-renders and overrides it at execution time, once real
    # host/role vars are available - parse time never has that context.
    property become_expr : String?
    property become_user : String?
    property tags : Array(String)
    property loop : Array(JSON::Any)?
    # Loop items already resolved at parse time (loop:, with_items:,
    # with_dict:, with_nested:, with_sequence:, with_indexed_items:).
    property loop_items : Array(JSON::Any)?
    # with_fileglob patterns, resolved at execution time (needs {{ vars }}
    # substitution and filesystem access, neither available at parse time).
    property loop_fileglob : Array(String)?
    # with_first_found candidate paths, resolved at execution time for the
    # same reasons as loop_fileglob. Unlike a glob this yields at most one
    # item - the first candidate that exists. loop_first_found_skip is the
    # `skip: true` form, which makes "none of them exist" a skipped task
    # rather than an error.
    property loop_first_found : Array(String)?
    property loop_first_found_skip : Bool
    # loop:/with_items:/with_dict:/with_nested:/with_indexed_items: given as
    # a Jinja variable reference ("{{ some_var }}") rather than a literal
    # inline list/dict. Unresolvable at parse time since the YAML value is
    # just a scalar string until the variable context exists, so the raw
    # source keyword and template string are carried for the executor to
    # resolve at execution time (mirrors loop_fileglob).
    property loop_template_kind : String?
    property loop_template : String?
    # with_community.general.flattened sources, kept as their raw task
    # strings. Each is ordinarily a `{{ some_list_var }}` reference to a
    # list; like loop_fileglob/loop_first_found they can only be resolved at
    # execution time once the variable context exists, so the parser stores
    # them verbatim and TaskExecutor flattens the resolved lists.
    property loop_flattened : Array(String)?
    # with_subelements: the raw list template (usually a `{{ registered_var
    # .results }}` reference) and the subelement key. Both kept verbatim and
    # resolved at execution time once the variable context + registered vars
    # exist.
    property loop_subelements_list : String?
    property loop_subelements_key : String?
    # loop_control.loop_var - the variable name the loop item is exposed
    # under (Ansible default "item"). Roles like dev-sec os_hardening set
    # `loop_control: { loop_var: mount }` so an include_tasks/loop can refer
    # to `mount.path`, `mount.owner`, etc. rather than always `item`. Kept
    # verbatim and resolved at execution time; nil means the default "item".
    property loop_var : String?
    # loop_control.index_var - exposes the current loop iteration's
    # zero-based index under this variable name (real Ansible's own
    # `loop_control: { index_var: idx }`, commonly paired with a
    # `register:`ed loop result so `some_registered.results[idx]` can be
    # looked up against the SAME item currently being processed - e.g.
    # `results[index].stat.exists` as a `when:` guard skipping re-work
    # already verified by an earlier per-item `stat:` loop). Previously
    # entirely unimplemented - parsed nowhere, injected into vars_context
    # nowhere - so `{{ index }}` (or whatever name was configured) always
    # resolved to "undefined" throughout the loop body, silently breaking
    # any downstream `results[index]` lookup. Found via robertdebock.
    # mount's own "Create mountpoint" task.
    property index_var : String?
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
    # connection: - overrides the connection plugin for just this task
    # (almost always "local"), independent of delegate_to: - it changes
    # HOW the task's module runs (locally on the controller vs. over
    # SSH), not WHICH host's vars/facts/register apply (that's still
    # delegate_to:'s job). robertdebock.backup's own "Create backup_
    # directory" (writes to the controller's filesystem while still
    # being attributed to the current host's own inventory_hostname)
    # uses exactly this combination: connection: local, no delegate_to:.
    property connection : String?
    # delegate_facts: - when true alongside delegate_to:, a module's
    # returned ansible_facts (set_fact:, fact-gathering modules) attach to
    # the delegate_to: target's own hostvars instead of the delegating
    # host's - real Ansible's own documented meaning ("apply facts to a
    # delegated host instead of the inventory_hostname"). register: is
    # unaffected either way (always attaches to the delegating host).
    property delegate_facts : Bool
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
    # The role's vars/ directory - where include_vars: and
    # with_first_found: resolve a relative filename from, the same way
    # role_files_dir serves copy:'s src:.
    property role_vars_dir : String?
    # The role's invocation name, exactly as written in `role:`/`name:`
    # (a bare name or a full local path) - exposed to templates as the
    # `ansible_role_name` magic var (dev-sec nginx_hardening's own
    # hardening.conf.j2: `# Generated by Ansible role {{ ansible_role_
    # name }}`). Real Ansible sets this to the same string the play
    # actually invoked the role with, not a normalized basename -
    # verified against a real ansible-playbook run using a full local
    # path for `role:`, which echoed that exact path back.
    property role_name : String?
    # The role's own root directory on disk - exposed to templates as the
    # `role_path` magic var (linux-system-roles/logging's own `include_role:
    # name: "{{ role_path }}/roles/rsyslog"`, a common pattern for a role to
    # reference one of its own private subroles by absolute path).
    property role_path : String?
    # The chain of ancestor role names (root-first, NOT including this
    # role's own name) that led to this role being invoked via
    # include_role: from within another role's own tasks - exposed as
    # the `ansible_parent_role_names` magic var. Empty/nil for a role
    # listed directly under a play's own `roles:` (not nested inside any
    # other role). Several real collections (prometheus.prometheus's own
    # `_common` shared-logic role, invoked by every exporter role) guard
    # against direct invocation with `ansible_parent_role_names is
    # defined and ansible_parent_role_names | length > 0`.
    property role_parent_names : Array(String)?
    # The `role_path` (filesystem root) of each ancestor role, same
    # ordering/population rules as role_parent_names above - real
    # Ansible searches a role task's ENTIRE parent-role chain (not just
    # the currently-executing role's own templates/files dir) for a
    # relative template:/copy: src:. Found via prometheus.prometheus._
    # common's own "Create systemd service unit" task: `src: "{{
    # _common_service_name }}.service.j2"` lives in the CALLING role's
    # own templates/ dir (node_exporter/templates/node_exporter.
    # service.j2), not _common's - a shared/generic role deliberately
    # relying on this real Ansible search-path behavior to let each
    # exporter role supply its own service unit template.
    property role_parent_paths : Array(String)?
    # The `namespace.collection` this task's own role belongs to -
    # exposed as the `ansible_collection_name` magic var, only ever set
    # for a role invoked via its full `namespace.collection.role` FQCN
    # (a collection-shipped role, as opposed to a plain Galaxy role
    # install). Several real collections use it to strip their own
    # namespace prefix back off `ansible_parent_role_names` (prometheus.
    # prometheus._common's own `regex_replace(ansible_collection_name ~
    # '.', '')`, computing a short service/tag name from the invoking
    # role's FQCN).
    property ansible_collection_name : String?
    # include_tasks: - only set when module_name == "_include_tasks".
    # Unlike import_tasks (resolved at parse time), the file path may be
    # templated ({{ vars }}) and isn't resolved until this task actually
    # runs, so both the raw path and the directory to resolve it against
    # (wherever the include_tasks: line itself lives) are carried on the
    # Task for the executor to use at run time.
    property include_file : String?
    property include_file_dir : String?
    # meta: - only set when module_name == "_meta". Holds the meta action
    # ("clear_facts"); see TaskExecutor#execute_meta.
    property meta_action : String?
    # include_vars: - only set when module_name == "_include_vars".
    # include_vars_file is the file to load (may be templated, so it is
    # resolved at run time); include_vars_name is the optional `name:`
    # parameter, which loads the file into a single dict variable of that
    # name instead of merging its keys into the context.
    property include_vars_file : String?
    property include_vars_name : String?
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
    # tasks_from: - loads tasks/<name>.yml instead of tasks/main.yml.
    # Common in collection-shipped "shared logic" roles (e.g.
    # prometheus.prometheus's own _common role, invoked repeatedly by
    # every exporter role with a different tasks_from: per call - one
    # role directory, several distinct task-file entry points).
    property include_role_tasks_from : String?
    # Synthesized by RoleLoader when a role has meta/argument_specs.yml -
    # only set when module_name == "_validate_argument_spec". Real Ansible
    # auto-inserts this as the role's first task ("Validating arguments
    # against arg spec 'main' - <short_description>"); holds the entry
    # point's `options:` map (name -> {type, required, ...}) for
    # TaskExecutor#execute_validate_argument_spec to check the effective
    # vars against.
    property validate_argument_spec_options : Hash(String, JSON::Any)?

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
      @loop_first_found = nil
      @loop_first_found_skip = false
      @loop_template_kind = nil
      @loop_template = nil
      @loop_flattened = nil
      @loop_subelements_list = nil
      @loop_subelements_key = nil
      @loop_var = nil
      @index_var = nil
      @until_condition = nil
      @retries = 3
      @delay = 5
      @changed_when = nil
      @failed_when = nil
      @delegate_to = nil
      @delegate_facts = false
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
      @role_vars_dir = nil
      @role_name = nil
      @role_parent_names = nil
      @role_parent_paths = nil
      @ansible_collection_name = nil
      @role_path = nil
      @include_file = nil
      @include_file_dir = nil
      @include_vars = nil
      @include_vars_file = nil
      @include_vars_name = nil
      @include_role_name = nil
      @include_role_vars = nil
      @include_role_dir = nil
      @include_role_tasks_from = nil
      @validate_argument_spec_options = nil
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

    def meta? : Bool
      @module_name == "_meta"
    end

    def include_vars? : Bool
      @module_name == "_include_vars"
    end

    def validate_argument_spec? : Bool
      @module_name == "_validate_argument_spec"
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
    # Whether the play actually wrote a `gather_facts:` key, as opposed to
    # defaulting to true. Only --gathering explicit needs the distinction:
    # under it, facts are gathered solely for plays that asked in so many
    # words, so "unset" and "explicitly true" cannot be conflated.
    property gather_facts_set : Bool = false
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
    # A Set, not an Array: this is membership-tested once per task in
    # parse_task and again per task in validate, and a linear scan of 44
    # entries is the wrong shape for a lookup table even where the cost
    # is unmeasurable.
    AVAILABLE_PLUGINS = Set{
      "ansible.builtin.copy",
      "ansible.builtin.template",
      "ansible.builtin.file",
      "ansible.builtin.lineinfile",
      "ansible.builtin.replace",
      "ansible.builtin.service",
      "ansible.builtin.systemd",
      "ansible.builtin.hostname",
      "ansible.builtin.shell",
      "ansible.builtin.apt",
      "ansible.builtin.dnf",
      "ansible.builtin.yum",
      "ansible.builtin.package",
      "ansible.builtin.debug",
      "ansible.builtin.command",
      "ansible.builtin.setup",
      "ansible.builtin.package_facts",
      "ansible.posix.selinux",
      "community.general.pam_limits",
      "community.general.capabilities",
      "community.general.make",
      "ansible.builtin.user",
      "ansible.builtin.group",
      "ansible.builtin.git",
      "ansible.builtin.pip",
      # community.general, not ansible.builtin - real Ansible's own gem
      # module has always lived in that collection, never ansible-core.
      # Registered under the wrong namespace before, so a role writing
      # the (correct, and far more common in practice) fully-qualified
      # `community.general.gem:` form - as opposed to the bare `gem:`
      # short name, which happened to still resolve via
      # MODULE_SEARCH_COLLECTIONS regardless of which FQCN this was
      # registered under - got "Plugin not available" and the whole
      # task silently dropped, even though plugins/gem.cr is a real,
      # working plugin. Found via robertdebock.travis's own "install
      # travis" task (`community.general.gem: {name: travis, ...}`).
      "community.general.gem",
      "ansible.builtin.cron",
      "ansible.posix.authorized_key",
      "ansible.builtin.stat",
      "ansible.builtin.find",
      "ansible.builtin.getent",
      "community.general.archive",
      "ansible.builtin.unarchive",
      "ansible.builtin.yum_repository",
      "ansible.builtin.apt_repository",
      "ansible.builtin.apt_key",
      "ansible.builtin.rpm_key",
      "ansible.posix.seboolean",
      "ansible.builtin.deb822_repository",
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
      "community.mysql.mysql_info",
      "community.mysql.mysql_query",
      # dev-sec's own mysql_hardening role writes every mysql module
      # under this FQCN instead of community.mysql.* - a real, distinct
      # collection namespace (not a typo in this repo), so both need
      # their own AVAILABLE_PLUGINS entries; get_local_plugin_path's own
      # FQCN-stripping regex strips both prefixes down to the same
      # plugin binary names.
      "ansible.mysql.mysql_db",
      "ansible.mysql.mysql_user",
      "ansible.mysql.mysql_info",
      "ansible.mysql.mysql_query",
      "community.postgresql.postgresql_db",
      "community.postgresql.postgresql_user",
      "community.postgresql.postgresql_privs",
      "community.crypto.openssl_dhparam",
      "community.crypto.openssh_keypair",
      "community.general.modprobe",
      "community.general.pamd",
      "community.general.htpasswd",
      "community.general.ini_file",
      "community.general.timezone",
      "community.general.npm",
      "community.general.alternatives",
      "community.general.filesystem",
      "ansible.builtin.service_facts",
      "ansible.builtin.slurp",
      # No plugins/reboot.cr - handled entirely on the controller by
      # TaskExecutor#execute_reboot (see that method's own comment for
      # why: unlike every other module, its process can't run ON the
      # target, since the target is about to reboot out from under it).
      # Listed here only so a reboot: task isn't silently dropped at
      # parse time as "Plugin not available".
      "ansible.builtin.reboot",
      "ansible.builtin.set_fact",
      "ansible.builtin.get_url",
      "ansible.builtin.blockinfile",
      "ansible.builtin.uri",
      "ansible.builtin.assert",
      "ansible.builtin.fail",
      "ansible.builtin.wait_for",
      "ansible.builtin.wait_for_connection",
      "ansible.builtin.ping",
      "ansible.builtin.fetch",
      "ansible.builtin.pause",
    }

    # The collections a bare (non-FQCN) module name resolves against, in
    # real Ansible's own default search order - `getent:` (no `ansible.
    # builtin.` prefix) is extremely common in real-world playbooks/roles
    # (dev-sec's own molecule test fixtures use it, unlike the role's own
    # tasks, which are always fully qualified) and previously only ever
    # matched AVAILABLE_PLUGINS verbatim, so any bare name failed outright
    # ("Plugin not available: getent") even though the qualified form
    # works fine. None of AVAILABLE_PLUGINS' short names collide across
    # collections, so the search order only matters for documentation
    # purposes here, not correctness.
    MODULE_SEARCH_COLLECTIONS = [
      "ansible.builtin", "ansible.legacy", "ansible.posix",
      "community.general", "community.docker", "community.mysql", "community.postgresql",
    ]

    # Modules whose bare-string task arg is a raw command line, not
    # free-form key=value params - see the yaml.as_s? branch of
    # #parse_module_params. Bare "command"/"shell" is included
    # defensively alongside the resolved FQCN forms, in case this is
    # ever reached before module_name resolution.
    RAW_COMMAND_MODULES = {
      "command", "shell",
      "ansible.builtin.command", "ansible.builtin.shell",
      "ansible.legacy.command", "ansible.legacy.shell",
    }

    # Resolves a task's module key (as written) to the AVAILABLE_PLUGINS
    # entry it refers to - itself unchanged if already fully qualified (or
    # a pseudo-module like "_block"), otherwise the first
    # MODULE_SEARCH_COLLECTIONS prefix that matches. nil if nothing
    # matches at all (a genuinely unimplemented/unknown module).
    # Real Ansible module aliases - a second FQCN (or bare name) that
    # resolves to the exact same module, not merely a similarly-named
    # one. `systemd_service` was added in ansible-core 2.12 as the
    # "correct" name (`systemd` was ambiguous with `systemd_service`/
    # `systemd_socket`... at the time only one of each ever shipped);
    # `systemd` is still kept as a working alias, and real-world roles
    # use both spellings interchangeably (konstruktoid/ansible-role-
    # hardening's own tasks write `ansible.builtin.systemd_service` 19
    # times across 14 files, never the bare `ansible.builtin.systemd`
    # this codebase's plugin is actually named after). Checked before
    # the AVAILABLE_PLUGINS/MODULE_SEARCH_COLLECTIONS lookups below, so
    # both spellings resolve to the one real plugin binary.
    MODULE_ALIASES = {
      "systemd_service"                 => "ansible.builtin.systemd",
      "ansible.builtin.systemd_service" => "ansible.builtin.systemd",
      "ansible.legacy.systemd_service"  => "ansible.builtin.systemd",
    }

    def self.resolve_module_name(raw : String) : String?
      return MODULE_ALIASES[raw] if MODULE_ALIASES.has_key?(raw)
      return raw if AVAILABLE_PLUGINS.includes?(raw) || raw.starts_with?('_')

      MODULE_SEARCH_COLLECTIONS.each do |collection|
        qualified = "#{collection}.#{raw}"
        return qualified if AVAILABLE_PLUGINS.includes?(qualified)
      end

      nil
    end

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
      play.become = parse_become_value(yaml["become"]?) || false
      play.become_user = yaml["become_user"]?.try(&.as_s)
      gather_facts_yaml = yaml["gather_facts"]?
      play.gather_facts = gather_facts_yaml ? gather_facts_yaml.as_bool : true
      play.gather_facts_set = !gather_facts_yaml.nil?

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

      # pre_tasks:/post_tasks: - real Ansible's execution order is
      # pre_tasks, then roles:, then tasks:, then post_tasks:. Previously
      # entirely unparsed (a play with only pre_tasks:/roles:, no tasks:
      # at all, silently ran nothing but the role - geerlingguy.docker/
      # mysql/postgresql/nginx/php/security's own molecule converge.yml
      # ALL use exactly this shape for an apt-cache-update pre_task).
      # Handler notify:/flush timing across section boundaries isn't
      # modeled separately - handlers notified from a pre_task still
      # flush at the same point regular tasks' handlers do - a
      # simplification, but the sequencing itself (which is what was
      # actually broken - pre_tasks silently never ran at all) is exact.
      pre_tasks = [] of Task
      if pre_tasks_yaml = yaml["pre_tasks"]?.try(&.as_a?)
        pre_tasks = parse_tasks(pre_tasks_yaml, play, "pre_task in play '#{name}'", playbook_dir)
      end

      # Parse roles: - their tasks/handlers run BEFORE the play's own
      # tasks:/handlers:, after any pre_tasks: (matching Ansible).
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

      post_tasks = [] of Task
      if post_tasks_yaml = yaml["post_tasks"]?.try(&.as_a?)
        post_tasks = parse_tasks(post_tasks_yaml, play, "post_task in play '#{name}'", playbook_dir)
      end

      play.tasks = pre_tasks + role_tasks + own_tasks + post_tasks

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
    def self.parse_tasks(tasks_yaml : Array(YAML::Any), play : Play, context : String, file_dir : String, known_vars : Hash(String, JSON::Any)? = nil) : Array(Task)
      tasks = [] of Task

      tasks_yaml.each_with_index do |task_yaml, index|
        begin
          if imported = try_parse_import_tasks(task_yaml, play, file_dir, known_vars)
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
    # Resolves an include_tasks:/import_tasks: file path, trying the
    # direct interpretation first (relative to *file_dir*, the
    # including file's own directory) and falling back to stripping a
    # leading `tasks/` from *file_rel* and retrying against the same
    # directory if that doesn't exist. Real Ansible's own include-path
    # search considers multiple roots (including the role root itself,
    # not just the including file's directory), so a role convention
    # like `include_tasks: tasks/foo.yml` written *inside* a file that's
    # already directly in `<role>/tasks/` resolves there correctly - our
    # single-root resolution doubled it into `<role>/tasks/tasks/foo.yml`
    # instead. Found via linux-system-roles' journald role, whose
    # tasks/main.yml does exactly this (`include_tasks: tasks/set_vars.
    # yml`) - a common enough convention (explicit `tasks/` prefix even
    # from within the tasks dir) that this isn't specific to one role.
    def self.resolve_include_path(file_rel : String, file_dir : String) : String
      direct = File.expand_path(file_rel, file_dir)
      return direct if File.exists?(direct)

      if file_rel.starts_with?("tasks/")
        stripped = File.expand_path(file_rel[6..], file_dir)
        return stripped if File.exists?(stripped)
      end

      direct
    end

    private def self.try_parse_import_tasks(yaml : YAML::Any, play : Play, file_dir : String, known_vars : Hash(String, JSON::Any)? = nil) : Array(Task)?
      hash = yaml.as_h?
      return nil unless hash

      import_value = directive(hash, "import_tasks")
      return nil unless import_value

      file_rel = import_value.as_h?.try(&.["file"]?).try(&.as_s?) || import_value.as_s?
      raise "import_tasks: missing a file path" unless file_rel

      # import_tasks:'s file path is templated against whatever's known
      # at PARSE time (role defaults/vars/invocation vars - never
      # runtime facts, matching real Ansible's own early-resolution
      # constraint for this keyword) before being resolved - openstack.
      # ansible-hardening's own `import_tasks: "{{ stig_version
      # }}stig/main.yml"` (105 of the role's ~112 tasks, gathering STIG
      # controls for the target OS) previously left the literal
      # unrendered "{{ stig_version }}stig/main.yml" as the path,
      # always "file not found" and silently skipping the entire STIG
      # control set with just a warning.
      if known_vars && file_rel.includes?("{{")
        file_rel = VarSubstitutor.new(vars: known_vars).substitute(file_rel)
      end

      resolved_path = resolve_include_path(file_rel, file_dir)
      raise "Imported tasks file not found: #{resolved_path}" unless File.exists?(resolved_path)

      imported_yaml = YAML.parse(Vault.maybe_decrypt(File.read(resolved_path)))
      raise "Imported tasks file must be a YAML list: #{resolved_path}" unless imported_yaml.as_a?

      imported_tasks = parse_tasks(imported_yaml.as_a, play, "task in imported #{resolved_path}", File.dirname(resolved_path), known_vars)

      import_when = hash["when"]?.try { |v| condition_to_string(v) }
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
        # Direct scalar form: `with_items: "{{ some_list | ... }}"`
        if str = value.as_s?
          return {key, str} if str.includes?("{{")
          next
        end
        # Single-element array form: `with_items: ["{{ some_list | ... }}"]`.
        # Real Ansible flattens with_items one level, so a one-element list
        # holding a template that expands to a list becomes that list.
        # dev-sec os_hardening's yum gpg-check writes it this way, with a
        # `map(attribute='path')` / `difference(...)` filter chain inside.
        #
        # Only when the element IS one bare `{{ ... }}` expression (after
        # stripping whitespace) - not merely *contains* one. A real, quite
        # different one-element-array idiom (geerlingguy.mysql's own
        # "Disallow root login remotely": `with_items: ["DELETE FROM
        # mysql.user WHERE User='{{ mysql_root_username }}' AND ..."]`) is
        # a single LITERAL loop item whose text happens to embed a
        # template - rendering it produces a plain string, not a list, so
        # it must stay one loop item, not be treated as "the whole array
        # is secretly a list-producing template". The old `includes?("{{")`
        # check couldn't tell these apart and always guessed "list
        # template", so this always bound `item` to nil ("undefined")
        # instead of the rendered SQL string.
        if arr = value.as_a?
          if arr.size == 1
            inner = arr.first?.try(&.as_s?)
            stripped = inner.try(&.strip)
            return {key, inner} if inner && stripped && stripped.starts_with?("{{") && stripped.ends_with?("}}")
          end
        end
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

      if include_yaml = directive(task_hash, "include_tasks")
        return parse_include_tasks(name, task_hash, include_yaml, play, file_dir)
      end

      if include_role_yaml = directive(task_hash, "include_role").try(&.as_h?)
        return parse_include_role(name, task_hash, include_role_yaml, play, file_dir)
      end

      # import_role: - real Ansible resolves this statically at parse
      # time (so its tasks/handlers become part of the play up front,
      # unlike include_role's runtime dynamic inclusion). This codebase
      # doesn't do a true static splice for it; reusing include_role's
      # runtime machinery is a pragmatic approximation - the common case
      # (unconditional, non-looped import with vars:, e.g.
      # robertdebock.node_red's `import_role: name: robertdebock.
      # service`) behaves identically either way. Previously entirely
      # unhandled - "import_role" fell through to the module-name
      # dispatch below, failed plugin resolution, and the whole task was
      # silently dropped with only a yellow parse-warning (no TASK
      # header, no error surfaced in the run) - a role using it appeared
      # to just skip a step instead of failing loudly.
      if import_role_yaml = directive(task_hash, "import_role").try(&.as_h?)
        return parse_include_role(name, task_hash, import_role_yaml, play, file_dir)
      end

      if meta_yaml = directive(task_hash, "meta")
        return parse_meta_task(name, meta_yaml)
      end

      if include_vars_yaml = directive(task_hash, "include_vars")
        return parse_include_vars_task(name, task_hash, include_vars_yaml)
      end

      # Find the module (first key that's not a special keyword)
      special_keys = ["name", "when", "register", "ignore_errors", "check_mode",
                      "diff", "become", "become_user", "tags", "args", "listen", "with_items", "loop",
                      "with_dict", "with_fileglob", "with_first_found", "with_nested", "with_sequence",
                      "with_flattened", "with_community.general.flattened", "with_subelements", "with_indexed_items", "until", "retries", "delay",
                      "loop_control", "notify", "changed_when", "failed_when", "delegate_to", "delegate_facts", "run_once", "connection",
                      "async", "poll", "vars", "environment",
                      "block", "rescue", "always", "import_tasks", "include_tasks", "include_role",
                      "import_role", "meta", "include_vars"]
      # ... and the same names fully qualified, since directive() accepts
      # either spelling and neither form is a module to dispatch on.
      special_keys += special_keys.map { |k| "ansible.builtin.#{k}" }
      special_keys += ["ansible.legacy.import_tasks", "ansible.legacy.include_tasks",
                       "ansible.legacy.include_role", "ansible.legacy.include_vars",
                       "ansible.legacy.meta"]

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

      # Check if plugin is available - resolving a bare (non-FQCN) name
      # like `getent:` against ansible.builtin/etc first, same as real
      # Ansible's own module search path.
      resolved_module_name = resolve_module_name(module_name)
      unless resolved_module_name
        raise "Plugin not available: #{module_name}"
      end
      module_name = resolved_module_name

      task = Task.new(name, module_name)

      # Parse module parameters
      task.params = parse_module_params(module_params.not_nil!, module_name)

      # args: - a sibling keyword (not nested inside the module's own
      # key) for extra params on a free-form module, real Ansible's own
      # idiom for command/shell's own stdin:/chdir:/creates:/etc when
      # the module's own value is a bare command string rather than a
      # dict (`command: "wg pubkey"` / `args: {stdin: "{{ key }}"}`).
      # Previously not in special_keys at all (risking being misread as
      # the module name itself if it happened to sort first) and never
      # merged into task.params regardless - githubixx.ansible_role_
      # wireguard's own public-key derivation feeds the private key via
      # exactly this pattern; without the merge, `wg pubkey` always ran
      # with empty stdin, always "Key is not the correct length or
      # format" - a confusing failure with no evident tie back to args:
      # never being read.
      if args_yaml = task_hash["args"]?.try(&.as_h?)
        parse_module_params(YAML::Any.new(args_yaml), module_name).each { |key, value| task.params[key] = value }
      end

      # Parse task-level settings - FIXED to handle boolean values safely
      task.when_condition = task_hash["when"]?.try { |v| condition_to_string(v) }
      task.register = task_hash["register"]?.try { |v| safe_yaml_to_string(v) }
      task.ignore_errors = parse_ignore_errors(task_hash["ignore_errors"]?)
      task.check_mode = parse_optional_bool_or_template(task_hash["check_mode"]?)
      task.diff_mode = parse_optional_bool_or_template(task_hash["diff"]?)
      task.become = resolve_become(task_hash, play)
      task.become_expr = become_expr(task_hash)
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

      # Parse environment: - real Ansible's per-task env-var-setting
      # keyword, used throughout konstruktoid-hardening (PATH overrides
      # around several `command:`/`shell:` tasks, `DEBIAN_FRONTEND:
      # noninteractive` around package installs). Previously not in
      # special_keys at all, so the parser misread "environment" itself
      # as the *module name* to dispatch on - failing plugin resolution
      # ("Plugin not available: environment") and silently skipping the
      # entire task, not just the env-var setting. Values are kept as
      # raw (unsubstituted) strings here, same as task.params - real
      # {{ }} substitution happens at execution time once the vars
      # context exists.
      if env_yaml = task_hash["environment"]?.try(&.as_h?)
        task.environment = Hash(String, String).new
        env_yaml.each { |key, value| task.environment.not_nil![key.to_s] = stringify_value(value) }
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
      #
      # Single-element-array template form first: `with_items: ["{{ list | ... }}"]`
      # (or loop:) is how roles write a one-item literal array holding a
      # template that expands to a list - Ansible flattens with_items one
      # level, so it becomes that list. Must be checked before the literal
      # array branch below, which would otherwise treat the array as one
      # literal item equal to the "{{ ... }}" string.
      if template_loop = find_loop_template(task_hash)
        task.loop_template_kind = template_loop[0]
        task.loop_template = template_loop[1]
      elsif loop_yaml = task_hash["loop"]?.try(&.as_a?)
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
      elsif with_first_found = task_hash["with_first_found"]?
        task.loop_first_found = parse_first_found(with_first_found)
        task.loop_first_found_skip = first_found_skip?(with_first_found)
      elsif with_fileglob = task_hash["with_fileglob"]?
        task.loop_fileglob = if with_fileglob.as_a?
                               with_fileglob.as_a.map(&.as_s)
                             else
                               [with_fileglob.as_s]
                             end
      elsif with_flattened = (task_hash["with_flattened"]? || task_hash["with_community.general.flattened"]?).try(&.as_a?)
        # `with_flattened:` (the short lookup-plugin-name alias real
        # playbooks actually write - confirmed via dev-sec.os-hardening's
        # own "find files with write-permissions for group" task, which
        # uses exactly this spelling, never the FQCN form) was entirely
        # unrecognized before - only `with_community.general.flattened:`
        # matched, so the whole `with_flattened:` keyword silently fell
        # through as an unrecognized task key. The task then ran exactly
        # ONCE, not looped at all, with `item` completely unbound -
        # `{{ item }}` rendered the literal string "undefined" into the
        # shell command, which then genuinely failed
        # ("find: 'undefined': No such file or directory").
        #
        # Each source is normally a `{{ var }}` reference to a list, so store
        # them verbatim and let TaskExecutor resolve + flatten at execution
        # time once the variable context exists (see resolve_loop_flattened).
        task.loop_flattened = with_flattened.map { |item| safe_yaml_to_string(item) }
      elsif with_subelements = task_hash["with_subelements"]?.try(&.as_a?)
        task.loop_subelements_list = with_subelements[0]?.try { |v| safe_yaml_to_string(v) }
        task.loop_subelements_key = with_subelements[1]?.try { |v| safe_yaml_to_string(v) }
      elsif template_source = find_loop_template(task_hash)
        # loop:/with_items:/with_dict:/with_nested:/with_indexed_items: given
        # as a "{{ variable }}" reference: not a literal array/hash at parse
        # time, so stash the raw keyword + template string for the executor
        # to resolve once the variable context exists.
        task.loop_template_kind = template_source[0]
        task.loop_template = template_source[1]
      end

      # loop_control.loop_var - exposes the loop item under a custom name
      # (Ansible default "item"). dev-sec os_hardening uses
      # `loop_control: { loop_var: mount }` so an include_tasks/loop drives
      # tasks that read `mount.path`, `mount.owner`, etc.
      if loop_control = task_hash["loop_control"]?.try(&.as_h?)
        task.loop_var = loop_control["loop_var"]?.try(&.as_s?)
        task.index_var = loop_control["index_var"]?.try(&.as_s?)
      end

      # Parse until / retries / delay
      task.until_condition = task_hash["until"]?.try { |v| safe_yaml_to_string(v) }
      task.retries = task_hash["retries"]?.try { |v| safe_yaml_to_string(v).to_i? } || 3
      task.delay = task_hash["delay"]?.try { |v| safe_yaml_to_string(v).to_i? } || 5

      # Parse changed_when / failed_when
      task.changed_when = task_hash["changed_when"]?.try { |v| condition_to_string(v) }
      task.failed_when = task_hash["failed_when"]?.try { |v| condition_to_string(v) }

      # Parse delegate_to / run_once
      task.delegate_to = task_hash["delegate_to"]?.try { |v| safe_yaml_to_string(v) }
      task.connection = task_hash["connection"]?.try { |v| safe_yaml_to_string(v) }
      task.delegate_facts = task_hash["delegate_facts"]?.try(&.as_bool) || false
      task.run_once = task_hash["run_once"]?.try(&.as_bool) || false

      # Parse async / poll
      task.async_seconds = task_hash["async"]?.try { |v| safe_yaml_to_string(v).to_i? }
      task.poll_seconds = task_hash["poll"]?.try { |v| safe_yaml_to_string(v).to_i? }

      task
    end

    # Parse a block: task - block:/rescue:/always: are each an array of
    # nested tasks (which may themselves be blocks, so this recurses
    # import_tasks:/include_tasks:/include_role:/include_vars:/meta: are
    # real Ansible *modules*, so a playbook may spell them either bare or
    # fully qualified (`ansible.builtin.import_tasks:`). Collection-style
    # FQCN is the modern convention and some widely-used roles - notably
    # dev-sec's os_hardening - use it exclusively, so matching only the
    # bare key silently skipped every one of their imports.
    #
    # block:/rescue:/always: are deliberately absent: those are playbook
    # *keywords*, not modules, and real Ansible does not accept an
    # `ansible.builtin.` prefix on them either.
    private def self.directive(task_hash : Hash(YAML::Any, YAML::Any), name : String) : YAML::Any?
      task_hash[name]? || task_hash["ansible.builtin.#{name}"]? || task_hash["ansible.legacy.#{name}"]?
    end

    # with_first_found: accepts either a bare list of candidate paths, or
    # real Ansible's dict form - `- files: [...]` with an optional
    # `skip: true` (and `paths:`, which this engine does not model: it
    # searches the role's own vars//files/ directories and the playbook
    # directory, which covers the cases relative paths are actually used
    # for). Only the first entry is read, matching how the dict form is
    # written in practice.
    private def self.parse_first_found(yaml : YAML::Any) : Array(String)
      if list = yaml.as_a?
        first = list.first?
        if first && (hash = first.as_h?)
          files = hash["files"]?
          return [] of String unless files
          return files.as_a?.try(&.map(&.as_s)) || [files.as_s]
        end
        return list.map(&.as_s)
      end

      [yaml.as_s]
    end

    private def self.first_found_skip?(yaml : YAML::Any) : Bool
      list = yaml.as_a?
      return false unless list
      first = list.first?
      return false unless first
      hash = first.as_h?
      return false unless hash

      hash["skip"]?.try(&.as_bool?) || false
    end

    # include_vars: - a controller-side pseudo-module ("_include_vars").
    # It reads a YAML file from the *controller* and merges it into the
    # variable context, so there is no plugin binary and nothing runs on
    # the target. Accepts the bare-string form (`include_vars: x.yml`) and
    # the dict form with `file:`/`name:`.
    private def self.parse_include_vars_task(name : String, task_hash : Hash(YAML::Any, YAML::Any), value : YAML::Any) : Task
      task = Task.new(name, "_include_vars")

      if hash = value.as_h?
        file = hash["file"]? || hash["path"]?
        raise "include_vars: requires a file (or a bare filename)" unless file
        task.include_vars_file = file.as_s
        task.include_vars_name = hash["name"]?.try(&.as_s?)
      else
        task.include_vars_file = value.as_s
      end

      task.when_condition = task_hash["when"]?.try { |v| condition_to_string(v) }
      task.ignore_errors = parse_ignore_errors(task_hash["ignore_errors"]?)

      if tags_yaml = task_hash["tags"]?
        task.tags = tags_yaml.as_a?.try(&.map(&.as_s)) || [tags_yaml.as_s]
      end

      # A task's own vars: was never parsed here at all (same gap
      # parse_block_task had before it was fixed) - linux-system-roles/
      # timesync's own `include_vars: "{{ lookup('first_found', ffparams)
      # }}" vars: ffparams: {files: [...], paths: [...]}` needs ffparams
      # visible when the file: expression is rendered; without this it
      # resolved undefined.
      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars = Hash(String, JSON::Any).new
        vars_yaml.each { |key, var_value| vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(var_value.to_json)) }
        task.vars = vars
      end

      # with_first_found: is the loop form this module is almost always
      # paired with - "load whichever of these files exists".
      if with_first_found = task_hash["with_first_found"]?
        task.loop_first_found = parse_first_found(with_first_found)
        task.loop_first_found_skip = first_found_skip?(with_first_found)
      elsif loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop_items = loop_yaml.map { |item| JSON.parse(item.to_json) }
      end

      task
    end

    # meta: - a pseudo-module ("_meta"), like block:/include_tasks:, that
    # acts on the executor's own state rather than running a plugin on a
    # target.
    #
    # `clear_facts` and `flush_handlers` are supported. `flush_handlers`
    # added in round 18 - found via robertdebock's own roles, several of
    # which (mysql, selinux, zabbix_repository, zabbix_server,
    # core_dependencies) use `ansible.builtin.meta: flush_handlers`
    # deliberately mid-role (e.g. flushing a "Update cache" handler
    # BEFORE a later task that needs the freshly-added repo's package
    # list) - skipping the task entirely, the previous behavior, isn't
    # just a display-order cosmetic gap here: it caused a genuine
    # functional divergence from real ansible-playbook (a package
    # install failing "Unable to locate package" because the apt cache
    # update handler ran at the very end of the play instead of
    # mid-role). Real Ansible's own end_play/end_host/refresh_inventory/
    # clear_host_errors/noop still act on execution-flow machinery this
    # engine models differently, so they're rejected outright rather than
    # silently accepted and ignored - a playbook whose `meta: end_play`
    # quietly did nothing would be far worse than one that fails to
    # parse. A documented scope cut: `meta:` was previously not supported
    # at all, so this is strictly additive.
    private def self.parse_meta_task(name : String, meta_yaml : YAML::Any) : Task
      action = meta_yaml.as_s?.try(&.strip)

      if action.nil? || action.empty?
        raise "meta: requires a string action (only 'clear_facts'/'flush_handlers' are supported)"
      end

      unless action == "clear_facts" || action == "flush_handlers"
        raise "meta: #{action} is not supported (only 'clear_facts'/'flush_handlers' are)"
      end

      task = Task.new(name, "_meta")
      task.meta_action = action
      task
    end

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
      task.when_condition = task_hash["when"]?.try { |v| condition_to_string(v) }
      task.ignore_errors = parse_ignore_errors(task_hash["ignore_errors"]?)
      task.become = resolve_become(task_hash, play)
      task.become_expr = become_expr(task_hash)
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user

      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end

      # A block's own `vars:` is inherited by every task nested inside it
      # (real Ansible scoping) - was never parsed at all here, so it
      # silently vanished even though TaskExecutor#propagate_role_context
      # already merges enclosing.vars into each nested task, because
      # enclosing.vars was always empty for a block. Found via
      # linux-system-roles/logging's `Check logging inputs` block, which
      # computes `__logging_input_names` at block level for a nested
      # looped task's `when:` to reference.
      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars = Hash(String, JSON::Any).new
        vars_yaml.each { |key, value| vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
        task.vars = vars
      end

      # A block's own `notify:` fires once if any task nested inside it
      # (block/rescue/always) changes, even when none of those nested
      # tasks have a notify: of their own - real Ansible's own
      # block-level notify semantics. Never parsed here at all before,
      # so TaskExecutor#execute_block/#execute_block_multi's own
      # block-notify handling had nothing to read regardless. Found via
      # robertdebock.swap's own "Manage swap files." block.
      if notify_yaml = task_hash["notify"]?
        task.notify = notify_yaml.as_s? ? [notify_yaml.as_s] : notify_yaml.as_a.map(&.as_s)
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

      task.when_condition = task_hash["when"]?.try { |v| condition_to_string(v) }
      task.ignore_errors = parse_ignore_errors(task_hash["ignore_errors"]?)
      task.become = resolve_become(task_hash, play)
      task.become_expr = become_expr(task_hash)
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
      # import_tasks, which doesn't support loop: at all). with_first_found:
      # is the other real-world combination - githubixx.ansible_role_
      # wireguard's own "Include tasks depending on OS" picks the file
      # itself this way (`include_tasks: {file: "{{ item }}"}` paired
      # with `with_first_found: [...]` candidates) - previously
      # unparsed, so `item` stayed completely unbound and the include's
      # own `{{ item }}" file path rendered to the literal text
      # "undefined", always "file not found". Not the full with_dict/
      # with_nested/etc set a normal task gets - a reasonable scope
      # limit given how rarely those combine with include_tasks in
      # practice.
      if template_loop = find_loop_template(task_hash)
        # The scalar-template form (`loop: "{{ users_groups }}"`) - by far
        # the more common real-world shape (robertdebock.users' own "Loop
        # over users_groups"/"Loop over users") than a literal YAML list.
        # Previously unhandled here entirely: task.loop_items stayed nil,
        # the include ran exactly once with no item bound, and any custom
        # loop_var (`group`/`user`) resolved as "undefined" throughout the
        # included file.
        task.loop_template_kind = template_loop[0]
        task.loop_template = template_loop[1]
      elsif loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop_items = loop_yaml.map { |item| JSON.parse(item.to_json) }
      elsif with_items = task_hash["with_items"]?.try(&.as_a?)
        task.loop_items = with_items.map { |item| JSON.parse(item.to_json) }
      elsif with_first_found = task_hash["with_first_found"]?
        task.loop_first_found = parse_first_found(with_first_found)
        task.loop_first_found_skip = first_found_skip?(with_first_found)
      end

      # loop_control.loop_var - expose each item under the custom name
      # (e.g. `mount` instead of `item`), as dev-sec os_hardening does for
      # its per-mountpoint include_tasks loop.
      if loop_control = task_hash["loop_control"]?.try(&.as_h?)
        task.loop_var = loop_control["loop_var"]?.try(&.as_s?)
        task.index_var = loop_control["index_var"]?.try(&.as_s?)
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
      task.include_role_tasks_from = include_role_yaml["tasks_from"]?.try(&.as_s)

      if vars_yaml = task_hash["vars"]?.try(&.as_h?)
        vars = Hash(String, JSON::Any).new
        vars_yaml.each { |key, value| vars[key.to_s] = Vault.maybe_decrypt_json(JSON.parse(value.to_json)) }
        task.include_role_vars = vars
      end

      task.when_condition = task_hash["when"]?.try { |v| condition_to_string(v) }
      task.ignore_errors = parse_ignore_errors(task_hash["ignore_errors"]?)
      task.become = resolve_become(task_hash, play)
      task.become_expr = become_expr(task_hash)
      task.become_user = task_hash["become_user"]?.try { |v| safe_yaml_to_string(v) } || play.become_user

      if tags_yaml = task_hash["tags"]?.try(&.as_a?)
        task.tags = tags_yaml.map(&.as_s)
      end

      if template_loop = find_loop_template(task_hash)
        task.loop_template_kind = template_loop[0]
        task.loop_template = template_loop[1]
      elsif loop_yaml = task_hash["loop"]?.try(&.as_a?)
        task.loop_items = loop_yaml.map { |item| JSON.parse(item.to_json) }
      elsif with_items = task_hash["with_items"]?.try(&.as_a?)
        task.loop_items = with_items.map { |item| JSON.parse(item.to_json) }
      end

      if loop_control = task_hash["loop_control"]?.try(&.as_h?)
        task.loop_var = loop_control["loop_var"]?.try(&.as_s?)
        task.index_var = loop_control["index_var"]?.try(&.as_s?)
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
          elsif module_name == "ansible.builtin.set_fact" && (value.as_a? || value.as_h?)
            # A literal list/dict-valued fact (`set_fact: my_list: ["a",
            # "b"]`, not a `{{ }}`-templated one) hits the exact same
            # comma-joining problem "assert.that" above already works
            # around - stringify_value's Array case comma-joins a list of
            # scalars ("a,b"), which is indistinguishable from a single
            # string containing a comma and has no leading `[`/`{` for
            # SetFactPlugin#coerce's own JSON-detection to catch. The
            # fact silently became a flat comma-joined String instead of
            # a real array - invisible until something reads it back as
            # a list, e.g. a later `loop: "{{ my_list }}"`, which then
            # saw a String (not an Array), failed to resolve any loop
            # items at all, and ran the task once with `item` undefined.
            # JSON-encoding here (like "that:") gives coerce's existing
            # leading-bracket check something real to detect.
            params[key.to_s] = value.to_json
          elsif (module_name == "ansible.mysql.mysql_query" || module_name == "community.mysql.mysql_query") && key.to_s == "query" && value.as_a?
            # `query:` as a list of independent SQL statements (dev-sec
            # mysql_hardening's own "Ensure that there are no users
            # without password" task) has the identical comma-joining
            # hazard "assert.that" already works around - a statement
            # legitimately containing a comma (very common in SQL) would
            # be indistinguishable from a statement boundary. JSON-
            # encoded here; MysqlQueryPlugin#parse_statements decodes it
            # back into an Array(String) on the plugin side.
            statements = value.as_a.map { |item| stringify_value(item) }
            params[key.to_s] = statements.to_json
          elsif key.to_s.in?({"mode", "directory_mode"}) && (raw = value.raw).is_a?(Int64 | Int32)
            # `mode: 0770` (unquoted, no string quotes - the way most
            # real playbooks write it) is genuinely ambiguous YAML: 1.1's
            # spec treats a leading-zero unquoted scalar as octal
            # notation, and Crystal's own YAML parser follows that,
            # silently resolving "0770" to the *decimal* value 504
            # (verified: `YAML.parse("mode: 0770")["mode"].raw` is the
            # Int64 504, not the string "0770"). #stringify_value's
            # normal Int64 handling (`yaml.as_i.to_s`) then produces the
            # literal string "504", which file.cr's own octal parser
            # (`mode.to_i(8)`) - expecting the *digit text* a user typed,
            # like real Ansible's own YAML loader preserves - reinterprets
            # as MORE octal digits, corrupting it a second time (504 -> a
            # chmod of 0o504 instead of the intended 0o770). Found
            # benchmarking cloudalchemy.prometheus's own directory/file
            # tasks, several of which use exactly this unquoted-mode
            # style and all silently got the wrong permissions - in one
            # case restrictive enough that the prometheus service user
            # couldn't even read its own config file at all.
            #
            # `raw.to_s(8)` re-derives the original octal digit text from
            # the (already-decimal-converted) integer value - the two
            # are bit-for-bit equivalent (504 decimal has the exact same
            # bit pattern as 0o770), so formatting it back through base 8
            # recovers "770", which file.cr's `to_i(8)` then parses back
            # to the same 504 - correctly, this time, since it's actually
            # being asked to parse octal digit text now.
            #
            # A leading "0" is prepended unconditionally - `Int#to_s(8)`
            # never includes one, but two of the three plugins that read
            # mode: (copy.cr, template.cr) branch on `mode.starts_with?
            # ("0")` to decide octal-vs-decimal (only file.cr's own
            # regex-based parse_numeric_mode treats the leading zero as
            # always-optional). Without it, "640" reached template.cr's
            # own parser as a bare *decimal* 640, chmod'ing prometheus's
            # own config file to an unreadable 1200 instead of 0640 -
            # found immediately after the fix above, on the very next
            # task in the same real-host round.
            params[key.to_s] = "0" + raw.to_s(8)
          else
            params[key.to_s] = Vault.maybe_decrypt(stringify_value(value))
          end
        end
      elsif yaml.as_s?
        # String format: single argument. Two real shapes: a raw command
        # line (`command: echo hello` / `shell: "{{ x }} -v"`, kept
        # verbatim - splitting THIS as key=value would corrupt any
        # command containing "=" at all, e.g. `VAR=1 somecommand`), or -
        # every other module - real Ansible's own free-form `key=value
        # key2=value2` inline syntax (`file: path="{{ p }}" mode=0640
        # owner=root`), the pre-YAML-dict-args way of writing task
        # params still used by real-world roles not written in this
        # codebase's own house style (dev-sec's own apache_hardening -
        # a much older, separately-maintained submodule with entirely
        # different task-writing conventions than the other 4 roles
        # benchmarked so far). Previously any non-command/shell module
        # given this way got dumped whole into `_raw_params`, a key only
        # command.cr/shell.cr/dnf.cr's own *free-form-name* fallback
        # ever reads - every param (`path=`, `mode=`, `owner=`, ...)
        # was silently discarded, and the task ran as if none of them
        # had been given at all.
        if RAW_COMMAND_MODULES.includes?(module_name)
          # Real bug found benchmarking geerlingguy.firewall's own
          # "Flush iptables the first time playbook runs." task:
          # `command: > iptables -F creates=/etc/firewall.bash` - real
          # Ansible's command:/shell: modules recognize a handful of
          # trailing key=value params (creates:, removes:, chdir:,
          # executable:) written inline this way, same as any other
          # module's free-form syntax, stripping them out of the actual
          # command text before running it. Previously the ENTIRE
          # string (options text included) was dumped verbatim into
          # cmd, so `iptables -F creates=/etc/firewall.bash` ran
          # literally - iptables tried to interpret "creates=..." as an
          # option/chain name and failed outright ("No chain/target/
          # match by that name"). Only strips from the *trailing end*
          # (repeatedly, for multiple such params) rather than
          # re-tokenizing the whole string, so a command containing its
          # own unrelated "=" text (`VAR=1 somecommand`, the general
          # case this class's own free-form key=value parsing
          # deliberately avoids for command:/shell:) is left untouched.
          cmd, special = extract_command_special_params(yaml.as_s)
          params["cmd"] = cmd
          special.each { |key, value| params[key] = value }
        else
          parse_inline_kv_params(yaml.as_s).each { |key, value| params[key] = value }
          params["_raw_params"] = yaml.as_s
        end
      else
        # Other types
        params["value"] = stringify_value(yaml)
      end

      params
    end

    # Parses real Ansible's free-form inline `key=value key2="quoted
    # value" key3='{{ a_template }}'` task-arg syntax into individual
    # params. Tokenizes on whitespace *outside* single/double quotes
    # (so a quoted value may itself contain spaces - `msg="hello
    # world"`, or a `{{ }}` expression with its own internal spaces),
    # splits each token on its first `=` (a value may legitimately
    # contain further `=` characters, e.g. base64 padding - only the
    # first one is the key/value separator), and strips one layer of
    # matching quotes from the value. A token with no `=` at all (a
    # malformed fragment, or the whole string is actually a bare
    # free-form value with no key=value pairs anywhere) is skipped, not
    # raised on - callers already fall back to `_raw_params` for that
    # case.
    private def self.parse_inline_kv_params(s : String) : Hash(String, String)
      params = Hash(String, String).new
      split_shell_like(s).each do |token|
        key, sep, value = token.partition('=')
        next if sep.empty? || key.empty?
        params[key] = unquote_inline_value(value)
      end
      params
    end

    private def self.split_shell_like(s : String) : Array(String)
      tokens = [] of String
      current = String::Builder.new
      quote : Char? = nil
      brace_depth = 0
      chars = s.chars
      i = 0

      while i < chars.size
        char = chars[i]
        next_char = i + 1 < chars.size ? chars[i + 1] : nil

        if q = quote
          current << char
          quote = nil if char == q
        elsif brace_depth > 0
          if (char == '{' && (next_char == '{' || next_char == '%')) ||
             (char == '}' && next_char == '}') || (char == '%' && next_char == '}')
            current << char << next_char.not_nil!
            brace_depth += 1 if char == '{'
            brace_depth -= 1 if char == '}' || char == '%'
            i += 1
          else
            current << char
          end
        elsif (char == '{' && (next_char == '{' || next_char == '%'))
          current << char << next_char.not_nil!
          brace_depth += 1
          i += 1
        elsif char == '\'' || char == '"'
          quote = char
          current << char
        elsif char.whitespace?
          if current.bytesize > 0
            tokens << current.to_s
            current = String::Builder.new
          end
        else
          current << char
        end
        i += 1
      end
      tokens << current.to_s if current.bytesize > 0
      tokens
    end

    private def self.unquote_inline_value(s : String) : String
      if (s.starts_with?('"') && s.ends_with?('"') && s.size >= 2) ||
         (s.starts_with?('\'') && s.ends_with?('\'') && s.size >= 2)
        s[1..-2]
      else
        s
      end
    end

    # Repeatedly strips a trailing " key=value" token (key one of
    # command:/shell:'s own recognized special params) off the end of
    # *raw*, returning the remaining command text and the extracted
    # params. Only ever touches the trailing end - the command body
    # itself, including any "=" it legitimately contains
    # (`VAR=1 somecommand`), is never re-tokenized or rewritten.
    #
    # Tokenizes via #split_shell_like (the same brace-depth-aware
    # scanner #parse_inline_kv_params already uses) rather than a
    # single backtracking regex over the whole string - two independent
    # regex-based attempts here each had a real bug, in OPPOSITE
    # directions, because a bare `\{\{.*?\}\}` alternative can't be
    # trusted to stop at the boundary of a single template block:
    #
    # 1. Under-matching: a value with exactly one `{{ }}` block and no
    #    further "}}" anywhere later in the string couldn't complete
    #    the pattern's trailing `\s*\z` at all, so extraction silently
    #    never happened (geerlingguy.solr's `creates={{
    #    solr_install_path }}/bin/solr`).
    # 2. Over-matching: with a SECOND "{{ }}" block later in the
    #    string, the lazy `.*?` could backtrack straight through an
    #    entire separate `key=value` param - including the space
    #    between them and that param's own braces - to reach that
    #    later "}}", silently absorbing it into the wrong param's
    #    value. geerlingguy.svn's own "Create a test repository." task,
    #    `svnadmin create testrepo chdir={{ svn_repository_home }}
    #    creates={{ svn_repository_home }}/testrepo/README.txt`, hit
    #    this: `chdir`'s value swallowed the entire trailing
    #    ` creates={{ ... }}/testrepo/README.txt` text as part of
    #    itself, so `chdir=` failed outright ("No such file or
    #    directory") on the resulting, never-a-real-path string.
    #
    # A brace-depth-tracking tokenizer (rather than backtracking regex
    # matching) can't make either mistake: it splits on whitespace
    # *outside* any `{{ }}`/`{% %}` span, so each `key=value` token's
    # boundary is exactly right regardless of how many template blocks
    # appear anywhere else in the string.
    private def self.extract_command_special_params(raw : String) : {String, Hash(String, String)}
      special = Hash(String, String).new
      tokens = split_shell_like(raw)

      while token = tokens.last?
        match = token.match(/\A(creates|removes|chdir|executable)=(.*)\z/m)
        break unless match

        tokens.pop
        key = match[1]
        special[key] ||= unquote_inline_value(match[2])
      end

      {tokens.join(" "), special}
    end

    # Helper: Safely convert any YAML value to string
    # This handles cases where YAML values might be booleans, integers, etc.
    # when:/changed_when:/failed_when: may each be given as a *list*, which
    # real Ansible ANDs together - it is the idiomatic way to write a
    # multi-clause condition and is used throughout widely-deployed roles
    # (dev-sec's os_hardening alone has 79 of them).
    #
    # This used to fall through safe_yaml_to_string's `else` branch to
    # `YAML::Any#to_s`, producing a Crystal array literal -
    # `["a_var", "'x' in pkgs"]` - as the condition string. That was
    # never evaluable: at best it was truthy by accident (a non-empty
    # string), and at worst it hung the run outright, because an element
    # containing " and " inside its quotes made ConditionalEvaluator
    # split on nothing and recurse on the identical string forever.
    #
    # Each element is parenthesized before joining so an element that is
    # itself a compound condition (`a or b`) cannot bind loosely against
    # its neighbours - `(a or b) and (c)`, not `a or b and c`.
    private def self.condition_to_string(yaml : YAML::Any) : String
      if list = yaml.as_a?
        clauses = list.map { |item| safe_yaml_to_string(item).strip }.reject(&.empty?)
        return "" if clauses.empty?
        return clauses[0] if clauses.size == 1

        return clauses.map { |clause| "(#{clause})" }.join(" and ")
      end

      safe_yaml_to_string(yaml)
    end

    # `ignore_errors:` accepts real Ansible's usual boolean-or-template
    # shorthand (e.g. dev-sec os_hardening's own `ignore_errors: "{{
    # ansible_check_mode }}"`, on a handler whose action doesn't work
    # inside a container) - but Task#ignore_errors is a plain Bool, parsed
    # eagerly here rather than deferred to runtime like `when:`/
    # `changed_when:` are. A bare `.as_bool` on a String value raises
    # ("Cast from String to Bool failed"), and that exception previously
    # propagated all the way up through the handler-parsing loop and
    # silently dropped the *entire* handler (name, action, when: - not
    # just this one field) with only a generic warning, matching neither
    # "true" nor "false" for that field but "the handler doesn't exist at
    # all". A plain "true"/"false"/"yes"/"no" literal still parses
    # normally; anything else (a template) falls back to `false` - which
    # is also the semantically correct value for this exact idiom outside
    # check mode, since `ansible_check_mode` is false on a real run.
    # `check_mode:`/`diff:` accept the same boolean-or-template shorthand
    # as `ignore_errors:`/`become:` (e.g. prometheus.prometheus.
    # alertmanager's own `configure.yml`: `diff: "{{ not
    # alertmanager_mask_diff }}"`) but were still using a bare `.as_bool`
    # call, which raises ("Cast from String to Bool failed") on anything
    # that isn't a literal YAML boolean. Unlike `ignore_errors:`/
    # `become:`, this exception wasn't just dropping the ONE task with
    # the templated value - it propagated out of #parse_task entirely and
    # aborted the REST of that task file's parsing too, silently dropping
    # every task after (and, depending on where the per-file rescue sits,
    # sometimes before) the offending one. Live symptom: the round-26
    # alertmanager role's "Copy alertmanager config" task (the one that
    # actually writes alertmanager's config file) and its neighbors in
    # the same `configure.yml` never appeared in the task list at all,
    # with only a generic parse-time warning far from the real cause.
    # `Bool?` (not the `false`-default `ignore_errors:` uses) is the
    # right fallback for a templated value here: `nil` means "not set,
    # inherit the global `--check`/`--diff` CLI flag", which is a safe,
    # neutral default that doesn't force either behavior on - closer to
    # what a runtime-deferred evaluation would usually produce than
    # guessing `true` or `false` outright.
    private def self.parse_optional_bool_or_template(yaml : YAML::Any?) : Bool?
      return nil unless yaml
      case yaml.raw
      when Bool
        yaml.as_bool
      when String
        case yaml.as_s.strip.downcase
        when "true", "yes", "on"
          true
        when "false", "no", "off"
          false
        else
          nil
        end
      else
        nil
      end
    end

    private def self.parse_ignore_errors(yaml : YAML::Any?) : Bool
      return false unless yaml
      case yaml.raw
      when Bool
        yaml.as_bool
      when String
        case yaml.as_s.strip.downcase
        when "true", "yes", "on"
          true
        when "false", "no", "off"
          false
        else
          false
        end
      else
        false
      end
    end

    # `become:`'s value at parse time - a literal YAML boolean the vast
    # majority of the time, but real Ansible also accepts a templated
    # string (`become: "{{ vault_privileged_install }}"`,
    # ansible-community.ansible-vault's own idiom). The old `.as_bool`
    # call raised outright for anything that wasn't a literal boolean
    # (YAML::Any#as_bool has no nil-safe variant that just returns nil
    # for a wrong type - it always raises), and that exception propagated
    # all the way up to parse_tasks' own per-task rescue, silently
    # dropping the ENTIRE task (not just mis-resolving become:) with only
    # a generic "Cast from String to Bool failed" warning nowhere near
    # obviously about become: at all.
    #
    # Full deferred (execution-time) evaluation of a templated become:
    # would need Task#become to become a runtime-resolved value instead
    # of a fixed Bool set once at parse time - real, but a bigger change
    # than this fix. A `{{ }}`-shaped string defaults to true here: real
    # playbooks essentially never write `become: "{{ x }}"` to mean "no,
    # don't" (a literal `become: false` is how that's actually
    # expressed), so this default is right far more often than a random
    # guess, and - critically - never worse than the previous behavior
    # of losing the whole task outright.
    private def self.parse_become_value(yaml : YAML::Any?) : Bool?
      return nil unless yaml
      case raw = yaml.raw
      when Bool
        raw
      when String
        return true if raw.strip.starts_with?("{{")
        raw.strip.downcase.in?("true", "yes", "1")
      else
        nil
      end
    end

    # A task's own become: falls back to the play's when not given at
    # all - but "not given" must mean exactly that, not merely falsy.
    # `parse_become_value(...) || play.become` (used until this helper
    # replaced it) treated an EXPLICIT `become: false` identically to
    # become: being absent entirely, since Bool false and nil are both
    # falsy to `||` - a task deliberately opting OUT of a play-level
    # `become: true` (ansible-community.ansible-vault's own "Check Vault
    # package file (local)": `become: false`, delegate_to: 127.0.0.1,
    # explicitly NOT wanting to sudo for a controller-side stat check)
    # silently kept becoming root anyway. Found investigating a stat:
    # task inexplicably failing with "sudo: a password is required"
    # despite its own explicit become: false.
    private def self.resolve_become(task_hash : Hash(YAML::Any, YAML::Any), play : Play) : Bool
      given = parse_become_value(task_hash["become"]?)
      given.nil? ? play.become : given
    end

    # Companion to #resolve_become: the raw `{{ ... }}` text of a
    # task-level `become:`, if it was a templated expression rather than
    # a literal boolean - nil otherwise (including when become: is
    # absent, in which case the play's own literal become: applies with
    # no re-rendering needed). Kept separate from #resolve_become rather
    # than changing its return type, since most call sites only need the
    # Bool and this keeps that path unchanged.
    private def self.become_expr(task_hash : Hash(YAML::Any, YAML::Any)) : String?
      yaml = task_hash["become"]?
      return nil unless yaml
      raw = yaml.raw
      return nil unless raw.is_a?(String)
      raw.strip.starts_with?("{{") ? raw.strip : nil
    end

    private def self.safe_yaml_to_string(yaml : YAML::Any) : String
      case yaml.raw
      when String
        yaml.as_s
      when Bool
        yaml.as_bool.to_s
      when Int64, Int32
        # yaml.as_i returns Int32 - raises "Arithmetic overflow" for any
        # value outside that range, silently dropping the WHOLE task at
        # parse time ("Skipping task ...: Arithmetic overflow", no
        # further detail). Real Ansible/YAML integers aren't bounded to
        # 32 bits - a uid: like 2147483659 (one past Int32::MAX, real
        # Linux allows uids up to UINT32_MAX) is completely ordinary.
        # Found via robertdebock.cve_2018_19788's own "Create user"
        # task (`uid: 2147483659`) - the whole task silently vanished,
        # not just that one field, so the role's actual test (a
        # non-privileged user shouldn't be able to manage a systemd
        # service) never ran against a real user at all.
        yaml.as_i64.to_s
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
        # yaml.as_i returns Int32 - raises "Arithmetic overflow" for any
        # value outside that range, silently dropping the WHOLE task at
        # parse time ("Skipping task ...: Arithmetic overflow", no
        # further detail). Real Ansible/YAML integers aren't bounded to
        # 32 bits - a uid: like 2147483659 (one past Int32::MAX, real
        # Linux allows uids up to UINT32_MAX) is completely ordinary.
        # Found via robertdebock.cve_2018_19788's own "Create user"
        # task (`uid: 2147483659`) - the whole task silently vanished,
        # not just that one field, so the role's actual test (a
        # non-privileged user shouldn't be able to manage a systemd
        # service) never ran against a real user at all.
        yaml.as_i64.to_s
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
        elsif task.include_vars? || task.meta? || task.validate_argument_spec?
          # Controller-side pseudo-modules (see their own Task field
          # comments) - never a real plugin binary, so never checked
          # against AVAILABLE_PLUGINS. Previously only reachable in
          # practice through a role's own include_tasks: (already
          # excluded above, hiding it), so this gap was never hit until
          # RoleLoader started emitting a "_validate_argument_spec" task
          # directly into play.tasks (unlike include_vars:/meta:, which
          # this codebase's roles only ever reach dynamically).
          [] of Task
        else
          [task]
        end
      end
    end
  end
end
