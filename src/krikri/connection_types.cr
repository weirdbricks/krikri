require "json"
require "./host"

module Krikri
  # The connection-type sets and the transport predicates shared by
  # PluginManager and ConnectionSettings.
  #
  # Kept deliberately free of ConnectionPluginLoader: every plugin binary
  # requires ConnectionSettings (through SSHManager), and pulling the
  # loader in here would pull role_loader/playbook_parser into every
  # plugin compile. The loader-aware half lives in
  # connection_type_loader.cr, which only the controller-side
  # PluginManager requires.
  #
  # Matching is CASE-SENSITIVE exactly like Ansible's own plugin loader,
  # which looks the name up verbatim against plugin filenames (no
  # lowercasing anywhere in the resolution path - verified live against
  # ansible-core 2.19.11: `connection: Local` fails the task with "the
  # connection plugin 'Local' was not found", and so does any FQCN that
  # names no real connection plugin, e.g. `community.grafana.grafana`).
  # "smart" is Ansible's default alias resolving to ssh for a remote
  # host; paramiko_ssh is still ssh for this engine's purposes.
  module ConnectionTypes
    extend self

    # All three spellings Ansible's amazon.aws collection accepts for the
    # native Session Manager connection (plan section 10, decision 2).
    SSM_CONNECTION_TYPES = Set{
      "aws_ssm", "amazon.aws.aws_ssm", "community.aws.aws_ssm",
    }

    LOCAL_CONNECTION_TYPES = Set{
      "local", "ansible.builtin.local", "ansible.legacy.local",
    }

    SSH_CONNECTION_TYPES = Set{
      "ssh", "smart", "paramiko_ssh",
      "ansible.builtin.ssh", "ansible.builtin.smart", "ansible.builtin.paramiko_ssh",
      "ansible.legacy.ssh", "ansible.legacy.smart", "ansible.legacy.paramiko_ssh",
    }

    # Connection plugins Ansible RESOLVES (shipped in ansible-core
    # itself, so the loader never returns not-found for them) but this
    # engine has no transport for: psrp/winrm (Windows), etc. They keep
    # the same "unknown connection falls back to SSH" behavior every
    # unimplemented-but-real connection plugin always had here - failing
    # them as "not found" would misreport a resolvable connection
    # (Ansible reaches an actual connection ATTEMPT for those, failing
    # with a connect error, not a resolution error).
    RESOLVABLE_UNIMPLEMENTED_CONNECTION_TYPES = Set{"psrp", "winrm"}

    # Names this engine can dispatch without asking Ansible's loader.
    def builtin?(raw : String) : Bool
      LOCAL_CONNECTION_TYPES.includes?(raw) ||
        SSH_CONNECTION_TYPES.includes?(raw) ||
        RESOLVABLE_UNIMPLEMENTED_CONNECTION_TYPES.includes?(raw) ||
        ssm?(raw)
    end

    # The fixed transport a built-in name implies, or nil for a name the
    # loader has to resolve.
    def builtin_transport(raw : String) : String?
      return "local" if LOCAL_CONNECTION_TYPES.includes?(raw)
      return "ssm" if ssm?(raw)
      return "ssh" if SSH_CONNECTION_TYPES.includes?(raw)
      return "ssh" if RESOLVABLE_UNIMPLEMENTED_CONNECTION_TYPES.includes?(raw)
      nil
    end

    def ssm?(raw : String) : Bool
      SSM_CONNECTION_TYPES.includes?(raw)
    end

    def local?(raw : String) : Bool
      LOCAL_CONNECTION_TYPES.includes?(raw)
    end

    # The effective raw ansible_connection name for *host*: the rendered
    # vars context first, then the host's own inventory setting. The merged
    # context already encodes Ansible's precedence (extra vars > task
    # connection: > play vars > inventory > the ssh default), including the
    # delegate's own connection for delegated tasks, so it must win.
    #
    # PluginManager.local_connection? deliberately keeps the host-first
    # order: its callers can pass a *foreign* origin context (round 195),
    # which must never override the target host's own inventory setting.
    # ConnectionSettings.resolve receives the exec host's own context, so
    # this order is correct there. nil means "no explicit connection",
    # which every caller treats as ssh.
    def resolved_name(host : Host, vars : Hash(String, JSON::Any)?) : String?
      (vars ? string_var(vars, "ansible_connection") : nil) ||
        string_var(host.vars, "ansible_connection")
    end

    # The raw SSM connection name when *host* resolves to one of the
    # SSM aliases, else nil.
    def ssm_name(host : Host, vars : Hash(String, JSON::Any)?) : String?
      name = resolved_name(host, vars)
      name if name && ssm?(name)
    end

    private def self.string_var(vars : Hash(String, JSON::Any), key : String) : String?
      text = vars[key]?.try(&.as_s?)
      return nil if text.nil? || text.empty?
      # An unrendered template is not a connection name - the same guard
      # ConnectionSettings#string_var uses; callers without a rendered
      # context must fall back rather than dial a literal "{{ x }}".
      return nil if text.includes?("{{") || text.includes?("{%")
      text
    end
  end
end
