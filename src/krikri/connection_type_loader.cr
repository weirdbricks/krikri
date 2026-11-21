require "./connection_types"
require "./connection_plugin_loader"

module Krikri
  # The loader-aware half of connection-type resolution. Split from
  # connection_types.cr so ConnectionSettings (and therefore every plugin
  # binary) does not drag Ansible's connection-plugin loader,
  # role_loader and playbook_parser into its compile.
  module ConnectionTypes
    extend self

    # Ansible's transport for *raw*: "local", "ssh" or "ssm", or nil when
    # Ansible's loader would not resolve the name either. A built-in name
    # (SSM aliases included) keeps its fixed transport BEFORE the loader
    # runs, so an installed amazon.aws collection cannot turn aws_ssm back
    # into the "resolved but not executable" failure. Any other resolvable
    # plugin resolves to the transport its own class implies, so the
    # local-vs-remote decisions around it never reach some other host.
    # Such a plugin is not runnable here though - see
    # connection_plugin_unsupported?.
    def transport(raw : String, playbook_dir : String? = nil) : String?
      if builtin = builtin_transport(raw)
        return builtin
      end

      source = ConnectionPluginLoader.find_source(raw, playbook_dir)
      return nil unless source

      ConnectionPluginLoader.local_source?(source) ? "local" : "ssh"
    end

    # Whether *raw* names no connection plugin Ansible could resolve
    # either - so a task using it must fail the way Ansible's
    # TaskExecutor._get_connection does, instead of silently falling back
    # to SSH.
    def not_found?(raw : String, playbook_dir : String? = nil) : Bool
      transport(raw, playbook_dir).nil?
    end

    # Whether *raw* names a connection plugin Ansible itself WOULD load
    # and execute but this engine cannot: a Python connection plugin found
    # on one of Ansible's loader paths. Its connection lifecycle
    # (_connect/exec_command/put_file/fetch_file) is the whole transport
    # layer SSH or local execution replaces here, so no transport
    # substitution can stand in for it. Tasks using one are failed
    # outright (connection_plugin_execution_failure) rather than run over
    # a different transport: that substitution is what made an SSM-style
    # plugin ssh to its `ansible_host=<instance id>` instead of reaching
    # the host (issues #1541, #1658).
    def unsupported?(raw : String, playbook_dir : String? = nil) : Bool
      return false if builtin?(raw)
      !ConnectionPluginLoader.find_source(raw, playbook_dir).nil?
    end
  end
end
