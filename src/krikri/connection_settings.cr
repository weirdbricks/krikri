require "./host"
require "./passwords"

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
  # Within one vars hash the *_ssh_user/_ssh_port/_ssh_host spellings are
  # the deprecated-but-honored aliases (build_vars_context already
  # synthesizes each alias from the other, but an explicitly-set alias
  # must still win when the canonical name is absent); the canonical
  # name is checked first, matching ansible-core's own option-var
  # aliasing order.
  struct ConnectionSettings
    getter conn_host : String
    getter user : String
    getter port : Int32?
    getter identity_file : String?
    getter password : String?
    getter common_args : Array(String)
    getter extra_args : Array(String)

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
      "ansible_ssh_private_key_file",
      "ansible_ssh_common_args", "ansible_ssh_extra_args",
      "ansible_become", "ansible_become_user",
      "ansible_become_password", "ansible_become_pass", "ansible_sudo_pass",
    ]

    def initialize(@conn_host : String, @user : String, @port : Int32?,
                   @identity_file : String?, @password : String?,
                   @common_args : Array(String), @extra_args : Array(String))
    end

    def self.resolve(host : Host, vars : Hash(String, JSON::Any)?) : ConnectionSettings
      # Tier order inside each lookup: the task's own vars context
      # (task > block > play > ... already merged by build_vars_context),
      # then the host's raw inventory vars - callers without a rendered
      # context (the pre-pass uses #resolve_play for the play layer) and
      # plugin-binary configs whose wire vars are pruned still see the
      # inventory's ansible_host/ansible_port/... exactly like the old
      # per-site reads did.
      user = tiered_var(vars, host, "ansible_user", "ansible_ssh_user") ||
             host.user || "root"
      port = port_var(vars) || port_var(host.vars) || host.port
      conn_host = tiered_var(vars, host, "ansible_host", "ansible_ssh_host") ||
                  host.name
      identity_file = tiered_var(vars, host, "ansible_ssh_private_key_file").presence
      password = Passwords.connection(vars, host)
      common_args = split_ssh_args(tiered_var(vars, host, "ansible_ssh_common_args"))
      extra_args = split_ssh_args(tiered_var(vars, host, "ansible_ssh_extra_args"))
      new(conn_host, user, port, identity_file, password, common_args, extra_args)
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
      merged = host.vars.dup
      play_vars.try do |vars|
        (CONNECTION_VAR_KEYS + Passwords::CONNECTION_KEYS).each do |key|
          merged[key] = vars[key] if vars.has_key?(key)
        end
      end
      resolve(host, merged)
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
       common_args.join('\u{1}'), extra_args.join('\u{1}')].join('\u{2}')
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

    private def self.port_var(vars : Hash(String, JSON::Any)?) : Int32?
      value = vars.try(&.["ansible_port"]?) || vars.try(&.["ansible_ssh_port"]?)
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
