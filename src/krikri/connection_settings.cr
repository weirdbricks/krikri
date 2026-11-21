require "./host"
require "./passwords"
require "./ansible_config"
require "./connection_types"
require "./ssm_settings"
require "./run_options"
require "system/user"

module Krikri
  # The SSH connection settings ONE task's dispatch must use - resolved
  # from the task's own vars_context (which already carries the full
  # Ansible precedence ladder: task vars > block vars (merged into
  # task.vars by the parser) > play vars > host/inventory vars, with -e
  # extra vars applied last inside build_vars_context) falling back to
  # the Host's inventory-level fields.
  #
  # Real ansible-core resolves every ssh connection option through the
  # connection plugin's var pipeline, so a task-level (or block/play
  # level) `vars:` entry - or a set_fact/include_vars/register chain -
  # changes the ACTUAL connection for that task, not just templating:
  # ansible_user/ansible_ssh_user, ansible_password/ansible_ssh_pass/
  # ansible_ssh_password, ansible_port/ansible_ssh_port,
  # ansible_host/ansible_ssh_host, ansible_ssh_private_key_file,
  # ansible_ssh_common_args and ansible_ssh_extra_args. Each task then
  # opens/reuses the connection keyed by the effective settings (the
  # ControlMaster socket is per (host, user, port)).
  #
  # Every consumer of an SSH transport in the task path (plugin dispatch,
  # daemon routing, plugin upload cache keys, batch script transport,
  # copy staging, async launch, reboot) resolves through this struct so
  # a task never silently runs over the inventory user's connection.
  #
  # The deprecated `ansible_ssh_*` spellings outrank the canonical names
  # wherever BOTH are present, regardless of which precedence tier each
  # came from: ansible-core resolves each connection option through
  # `ConfigManager._loop_entries` over the plugin's flat `vars:` name list
  # (ssh.py: user [ansible_user, ansible_ssh_user], host, port - same for
  # the become plugin's password chain), and that loop keeps the LAST
  # entry found in the one merged task-vars dict, so a role default's
  # `ansible_ssh_user: core` beats an inventory `ansible_user: root`
  # (tyranron.coreos_bootstrap, issue #887: ansible dialed core@ - the
  # role is CoreOS-only - and went UNREACHABLE while this engine dialed
  # the inventory user and got further). So every lookup here tries the
  # legacy spelling across BOTH tiers before the canonical one. Within
  # one name the vars context (already merged by build_vars_context)
  # outranks the host's raw inventory vars, ansible's own order.
  struct ConnectionSettings
    getter conn_host : String
    getter user : String
    getter port : Int32?
    getter identity_file : String?
    getter password : String?
    getter common_args : Array(String)
    getter extra_args : Array(String)
    # The ssh client binary this connection must dial with - ansible's
    # ssh_executable option (`ansible_ssh_executable`; issue #1483). nil is
    # that option's own default: plain `ssh` from PATH.
    getter ssh_executable : String?
    # The inventory host name this dispatch belongs to. SSHManager's
    # per-host state is keyed by connect address, but the SSM registry
    # must key by the inventory name so two names for one instance do not
    # alias one session.
    getter host_name : String
    # The raw effective ansible_connection name (an inventory/play/task
    # var), nil when no explicit one is set. Only SSM resolution needs it
    # today; it also lets play_context report the raw name instead of
    # falling back to "ssh".
    getter connection_type : String?
    # Non-nil only when connection_type is one of the SSM aliases.
    getter ssm : SsmSettings?
    # ssh.py's host_key_checking option, vars layer: the resolved
    # ansible_host_key_checking/ansible_ssh_host_key_checking value for
    # this connection, nil when no variable set it anywhere (env,
    # ansible.cfg and the True default then decide - resolved in
    # SSHManager, which also registers this value per connection spec so
    # its connection-less later calls reuse it; issue #1682).
    getter host_key_checking : Bool?

    # Every variable name that can change the actual SSH connection (or
    # its escalation) for a task. TaskBatcher solos any task whose own
    # task.vars carries one of these - a task that switches the
    # connection must never share a batch round trip with a neighbor
    # that connects differently.
    CONNECTION_VAR_KEYS = [
      "ansible_user", "ansible_ssh_user",
      "ansible_password", "ansible_ssh_pass", "ansible_ssh_password",
      "ansible_port", "ansible_ssh_port",
      "ansible_host", "ansible_ssh_host",
      "ansible_ssh_private_key_file", "ansible_private_key_file",
      "ansible_ssh_common_args", "ansible_ssh_extra_args",
      "ansible_ssh_executable",
      "ansible_host_key_checking", "ansible_ssh_host_key_checking",
      "ansible_become", "ansible_become_user",
      "ansible_become_password", "ansible_become_pass", "ansible_sudo_pass",
      "ansible_connection",
      "ansible_aws_ssm_instance_id", "ansible_aws_ssm_region",
      "ansible_aws_ssm_profile", "ansible_aws_ssm_document",
      "ansible_aws_ssm_timeout", "ansible_aws_ssm_retries",
      "ansible_aws_ssm_endpoint_url",
      "ansible_aws_ssm_access_key_id", "aws_access_key_id",
      "ansible_aws_ssm_secret_access_key", "aws_secret_access_key",
      "ansible_aws_ssm_session_token",
      "ansible_aws_ssm_plugin", "ansible_aws_ssm_bucket_name",
      "ansible_aws_ssm_s3_addressing_style", "s3_addressing_style",
    ]

    # The identity Ansible's aws_ssm connection uses as `remote_user`:
    # the controller's own username (`getpass.getuser()`), not ansible_user.
    # The session's OS user is whatever the SSM document runs as, so using
    # ansible_user here can make `become: true` skip the sudo wrap when
    # become_user happens to equal it.
    def become_baseline_user : String?
      ssm? ? ConnectionSettings.controller_username : user
    end

    @@controller_username : String?

    def self.controller_username : String?
      @@controller_username ||= begin
        System::User.find_by?(id: LibC.getuid.to_s).try(&.username) || ENV["USER"]?
      rescue
        ENV["USER"]?
      end
    end

    def initialize(@conn_host : String, @user : String, @port : Int32?,
                   @identity_file : String?, @password : String?,
                   @common_args : Array(String), @extra_args : Array(String),
                   @ssh_executable : String? = nil, @host_name : String = "",
                   @connection_type : String? = nil, @ssm : SsmSettings? = nil,
                   @host_key_checking : Bool? = nil)
    end

    def self.resolve(host : Host, vars : Hash(String, JSON::Any)?) : ConnectionSettings
      # Tier order inside each lookup: the task's own vars context
      # (task > block > play > ... already merged by build_vars_context),
      # then the host's raw inventory vars - callers without a rendered
      # context (the pre-pass uses #resolve_play for the play layer) and
      # plugin-binary configs whose wire vars are pruned still see the
      # inventory's ansible_host/ansible_port/... exactly like the old
      # per-site reads did.
      # Legacy spelling first across both tiers, then the canonical one -
      # see the deprecated-alias comment on the struct for why (ansible's
      # last-entry-wins var chain, issue #887).
      user = tiered_var(vars, host, "ansible_ssh_user") ||
             tiered_var(vars, host, "ansible_user") ||
             host.user || default_connection_user
      port = port_var(vars, "ansible_ssh_port") || port_var(host.vars, "ansible_ssh_port") ||
             port_var(vars, "ansible_port") || port_var(host.vars, "ansible_port") ||
             host.port
      conn_host = tiered_var(vars, host, "ansible_ssh_host") ||
                  tiered_var(vars, host, "ansible_host") ||
                  host.name
      # The identity ladder is ansible's ssh.py private_key_file option
      # exactly: both variable spellings (its vars list is
      # [ansible_private_key_file, ansible_ssh_private_key_file] and the
      # config manager keeps the LAST entry found, so the deprecated
      # spelling outranks the canonical one - the same story as the
      # user/host/port aliases above), then ANSIBLE_PRIVATE_KEY_FILE
      # below every variable (issue #1067: the env form of ansible's
      # PRIVATE_KEY_FILE setting was ignored entirely).
      identity_file = tiered_var(vars, host, "ansible_ssh_private_key_file") ||
                      tiered_var(vars, host, "ansible_private_key_file") ||
                      configured_private_key_file
      password = Passwords.connection(vars, host)
      common_args = split_ssh_args(tiered_var(vars, host, "ansible_ssh_common_args"))
      extra_args = split_ssh_args(tiered_var(vars, host, "ansible_ssh_extra_args"))
      connection_type = ConnectionTypes.resolved_name(host, vars)
      host_key_checking = resolved_host_key_checking_var(vars, host)
      new(conn_host, user, port, identity_file, password, common_args, extra_args,
        executable_setting(vars, host), host.name, connection_type,
        ssm_settings_for(host, vars, connection_type), host_key_checking)
    end

    # The vars-layer host_key_checking of one connection: the deprecated
    # ansible_ssh_ spelling first (see #host_key_checking_var for why),
    # the canonical name only when the alias left it unset. Spelled with
    # explicit nil checks - a Bool? result is falsy for `false` itself,
    # so a plain `||` would skip a deliberate `false`.
    private def self.resolved_host_key_checking_var(vars : Hash(String, JSON::Any)?, host : Host) : Bool?
      alias_value = host_key_checking_var(vars, host, "ansible_ssh_host_key_checking")
      alias_value.nil? ? host_key_checking_var(vars, host, "ansible_host_key_checking") : alias_value
    end

    private def self.ssm_settings_for(host : Host, vars : Hash(String, JSON::Any)?,
                                      connection_type : String?) : SsmSettings?
      return nil unless connection_type
      return nil unless ConnectionTypes.ssm?(connection_type)
      SsmSettings.resolve(host, vars)
    end

    # ansible's ssh_executable option. It has no deprecated alias, and its
    # ANSIBLE_SSH_EXECUTABLE env form sits below every variable
    # (ConfigManager's vars-before-env order, like the identity file above).
    private def self.executable_setting(vars : Hash(String, JSON::Any)?, host : Host) : String?
      tiered_var(vars, host, "ansible_ssh_executable") || configured_ssh_executable
    end

    # With no user anywhere in the ladder (no ansible_user var, no
    # inventory user, no remote_user:), real ansible-core hands ssh NO
    # -l/-u at all - live-verified against 2.19.11: the -vvv log reads
    # "ESTABLISH SSH CONNECTION FOR USER: None" and the ssh argv carries
    # no -l - so ssh connects as the LOCAL user, and `become: true` only
    # escalates through sudo on the target. This engine used to fall back
    # to "root" here, which silently dialed every user-less inventory as
    # root and failed key auth on hosts that only accept the admin user
    # (issue #679). Resolved from the process's own uid (falling back to
    # $USER), memoized - the same resolution PluginManager.local_username
    # uses for the local connection.
    #
    # ANSIBLE_REMOTE_USER - the env form of ansible's DEFAULT_REMOTE_USER
    # setting - sits ABOVE that fallback and below every user variable
    # (verified 2.21.6: an inventory ansible_user still wins over it,
    # which is ConfigManager._loop_entries' vars-before-env order), so it
    # is consulted on every call while only the uid lookup is memoized
    # (issue #1067).
    @@default_connection_user : String? = nil

    def self.default_connection_user : String
      if env_user = configured_remote_user
        return env_user
      end
      @@default_connection_user ||= begin
        System::User.find_by?(id: LibC.getuid.to_s).try(&.username) ||
        ENV["USER"]? || "root"
      rescue
        ENV["USER"]? || "root"
      end
    end

    # The two connection settings ansible resolves from its config
    # (DEFAULT_REMOTE_USER / PRIVATE_KEY_FILE). remote_user also comes
    # from ansible.cfg's `[defaults] remote_user` (AnsibleConfig), which
    # outranks the local-uid fallback but still loses to every connection
    # variable and -u; private_key_file stays env-only. Presence-checked
    # because ansible's ssh plugin only applies a TRUTHY value
    # (`if self.user:` / `elif key := self.get_option('private_key_file')`):
    # an empty variable is the same as none there, leaving ssh to pick its
    # own default user/identities.
    def self.configured_remote_user : String?
      ENV["ANSIBLE_REMOTE_USER"]?.presence || AnsibleConfig.remote_user
    end

    def self.configured_private_key_file : String?
      ENV["ANSIBLE_PRIVATE_KEY_FILE"]?.presence
    end

    def self.configured_ssh_executable : String?
      ENV["ANSIBLE_SSH_EXECUTABLE"]?.presence
    end

    # WHY: every connection key is resolved through the SAME two
    # tiers - the task's rendered vars context (task > block > play
    # > ..., already merged into one hash by build_vars_context)
    # first, then the host's raw inventory vars - so a block- or
    # play-level `vars:` entry outranks the inventory exactly the
    # way ansible-core's connection var pipeline orders them. Within
    # each tier the canonical spelling is tried before the deprecated
    # alias, preserving the original all-of-vars-then-all-of-inventory
    # evaluation order exactly.
    private def self.tiered_var(vars : Hash(String, JSON::Any)?, host : Host, key : String, alias_key : String? = nil) : String?
      string_var(vars, key) ||
        (alias_key ? string_var(vars, alias_key) : nil) ||
        string_var(host.vars, key) ||
        (alias_key ? string_var(host.vars, alias_key) : nil)
    end

    # The play-level view of a host's connection: play vars outrank
    # inventory host vars (live-verified vs ansible-playbook 2.19.11),
    # but a play that sets no connection vars must still see the
    # inventory's ansible_host/ansible_port/ansible_user. Used by the
    # play-start plugin pre-pass, which holds the raw play vars and has
    # no rendered per-task context.
    def self.resolve_play(host : Host, play_vars : Hash(String, JSON::Any)?) : ConnectionSettings
      keys = CONNECTION_VAR_KEYS + Passwords::CONNECTION_KEYS
      merged = host.vars.dup
      play_vars.try do |vars|
        keys.each do |key|
          merged[key] = vars[key] if vars.has_key?(key)
        end
      end
      # Extra vars outrank every variable scope in Ansible's precedence,
      # and the pre-upload pass has no rendered task context to read them
      # from. RunOptions.extra_vars is the CLI's parsed -e view.
      extra = RunOptions.extra_vars
      keys.each do |key|
        merged[key] = extra[key] if extra.has_key?(key)
      end
      resolve(host, merged)
    end

    def ssm? : Bool
      !@ssm.nil?
    end

    # The OS user the SSM session actually runs as (ssm-user for a
    # standard shell document), or the SSH user otherwise. Staging paths
    # use this so an SSM run never writes into the tree a later SSH run as
    # root/admin would verify as its own.
    def staging_user : String
      ssm? ? SsmSettings::SESSION_OS_USER : user
    end

    # The (host, user, port) spec every SSHManager transport and every
    # controller-side cache (plugin upload sets, daemon processes,
    # ControlMaster sockets, registered connection passwords) is keyed
    # on - the exact string shape PluginManager's existing host keys use.
    def spec_key : String
      "#{user}@#{conn_host}:#{port}"
    end

    # Full equality basis for batch eligibility: two steps may share one
    # SSH round trip only when they open the exact same connection the
    # exact same way.
    def fingerprint : String
      [conn_host, user, port.to_s, identity_file.to_s, password.to_s,
       common_args.join('\u{1}'), extra_args.join('\u{1}'),
       ssh_executable.to_s, ssm.try(&.identity_key).to_s].join('\u{2}')
    end

    # The `-o`-style argv every ssh/scp/rsync invocation for THIS
    # connection must carry (ansible_ssh_common_args first, then
    # ansible_ssh_extra_args, exactly like ansible-core's own
    # ssh_common_args/ssh_extra_args connection options). One method so
    # no call site can spell the combination itself and forget half of
    # it - the failure mode behind issue #2, where a path built its
    # transport argv from the identity file and port alone and let ssh
    # walk every agent identity instead of honoring IdentitiesOnly=yes.
    def ssh_extra_options : Array(String)
      common_args + extra_args
    end

    # Boolean-typed read for ssh.py's host_key_checking option, vars
    # layer. Within one name the task's rendered vars context outranks the
    # host's raw inventory vars (tiered_var's two-tier order); across the
    # two names the caller tries the deprecated ansible_ssh_ spelling
    # first because ssh.py's vars list is [ansible_host_key_checking,
    # ansible_ssh_host_key_checking] and ConfigManager._loop_entries keeps
    # the LAST entry found - the same rule as the identity file above.
    # The value may arrive as a real JSON boolean, an integer or a string
    # coerced by ansible's convert_bool non-strict boolean (its true set
    # only). An unrendered template or an unparseable string reads as
    # unset, deferring to env/ini/default downstream instead of silently
    # flipping the setting (issue #1682).
    private def self.host_key_checking_var(vars : Hash(String, JSON::Any)?, host : Host, key : String) : Bool?
      value = vars.try(&.[key]?) || host.vars[key]?
      return nil unless value
      case raw = value.raw
      when Bool   then raw
      when Int64  then raw != 0
      when String then AnsibleConfig.boolean(raw) unless raw.empty? || raw.includes?("{{") || raw.includes?("{%")
      end
    end

    private def self.string_var(vars : Hash(String, JSON::Any)?, key : String) : String?
      value = vars.try(&.[key]?)
      return nil unless value
      text = value.as_s?
      return nil if text.nil? || text.empty?
      # An unrendered Jinja template can only be seen here by callers
      # without a rendered vars context (the play-start plugin pre-pass
      # reads raw play vars). The task executor renders every connection
      # key eagerly in build_vars_context, so at dispatch time a value
      # that still looks like a template is one whose render FAILED -
      # using "{{ x }}" as a literal user/port would dial a garbage
      # target; ignoring it falls back to the inventory identity instead
      # (see build_vars_context's own comment for the tradeoff).
      return nil if text.includes?("{{") || text.includes?("{%")
      text
    end

    private def self.port_var(vars : Hash(String, JSON::Any)?, key : String) : Int32?
      value = vars.try(&.[key]?)
      return nil unless value
      return nil if (value.as_s?.try { |candidate| candidate.includes?("{{") || candidate.includes?("{%") })
      value.as_i? || value.as_s?.try(&.to_i?)
    end

    # shlex-style split of an ssh-args string (posix shell word rules:
    # whitespace separators, single/double quoting, backslash escapes) -
    # what ansible-core's own `shlex.split` does to these vars.
    def self.split_ssh_args(text : String?) : Array(String)
      return [] of String unless text
      args = [] of String
      current = IO::Memory.new
      quoted = false
      i = 0
      while i < text.size
        char = text[i]
        case char
        when ' ', '\t', '\n', '\r'
          if quoted || current.size > 0
            args << current.to_s
            current.clear
            quoted = false
          end
        when '\'', '"'
          quoted = true
          i = scan_quoted(text, i, current, char)
        when '\\'
          if i + 1 < text.size
            current << text[i + 1]
            i += 1
          end
        else
          current << char
        end
        i += 1
      end
      args << current.to_s if current.size > 0 || quoted
      args
    end

    # WHY: both quote styles scan forward to their closing quote,
    # and the double-quoted form additionally honors backslash
    # escapes for \" \\ $ ` - pulling that scan out of
    # split_ssh_args keeps the per-character dispatch flat while
    # producing byte-identical output: the helper only ever
    # appends to *current* and returns the index of the closing
    # quote (text.size for an unterminated span), which the
    # caller then steps past exactly as the inline loops did.
    private def self.scan_quoted(text : String, i : Int32, current : IO::Memory, quote : Char) : Int32
      j = i + 1
      while j < text.size && text[j] != quote
        if quote == '"' && text[j] == '\\' && j + 1 < text.size && {'"', '\\', '$', '`'}.includes?(text[j + 1])
          current << text[j + 1]
          j += 1
        else
          current << text[j]
        end
        j += 1
      end
      j
    end
  end
end
