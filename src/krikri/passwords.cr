require "./host"

module Krikri
  # Resolution of the two password values (-k/--ask-pass/-K/--ask-become-pass
  # and the *-password-file flags all land them as inventory host vars) from
  # the vars hash a dispatch site already holds. Shared by PluginManager
  # (become), SSHManager's registration path (connection), TaskExecutor's
  # batch/async builders and the synchronize action plugin, so every consumer
  # agrees on the key names and the "empty string is not a password" rule.
  #
  # Key lists mirror ansible-core's own: the ssh connection plugin's
  # `password` option vars (ansible_password/ansible_ssh_pass/
  # ansible_ssh_password) and the sudo become plugin's `become_pass` vars
  # (ansible_become_password/ansible_become_pass/ansible_sudo_pass).
  module Passwords
    CONNECTION_KEYS = ["ansible_password", "ansible_ssh_pass", "ansible_ssh_password"]
    BECOME_KEYS     = ["ansible_become_password", "ansible_become_pass", "ansible_sudo_pass"]

    # Where -K/--ask-become-pass and --become-password-file land: a registry
    # keyed by host name, NOT a host var. Ansible-core keeps the CLI-supplied
    # become password in its passwords dict (cli/__init__.py ask_passwords ->
    # PlayContext#initialize) and injects it into the become plugin below any
    # ansible_become_password variable - config resolution reads the variables
    # layer before the task_keys layer the CLI value rides on. Publishing it
    # as a host var made the secret template-visible: `debug: var=
    # ansible_become_password` printed it (issue #1690), where real ansible
    # reports the variable undefined.
    @@cli_become_passwords = {} of String => String

    # Registers the CLI-supplied become password for every host the entry
    # point selected. An empty answer (a bare Enter on the -K prompt, or an
    # empty --become-password-file) registers nothing - ansible-core treats
    # an empty value the same way (task_executor only hands a truthy
    # play_context.become_pass to the become plugin), so no empty variable
    # and no empty password ever exist.
    def self.register_cli_become_password(host_name : String, password : String) : Nil
      @@cli_become_passwords[host_name] = password unless password.empty?
    end

    # Test helper: the registry is process-wide state.
    def self.clear_cli_become_passwords : Nil
      @@cli_become_passwords.clear
    end

    # Task-level *vars* first (Ansible's task-var precedence over inventory),
    # then the host's own inventory vars - dispatch sites pass the full
    # vars_context, but a couple (batch daemon routing, the async launch
    # builder) only hold the Host, so both sources are consulted.
    def self.connection(vars : Hash(String, JSON::Any)?, host : Host? = nil) : String?
      lookup(CONNECTION_KEYS, vars, host)
    end

    def self.become(vars : Hash(String, JSON::Any)?, host : Host? = nil) : String?
      lookup(BECOME_KEYS, vars, host) || cli_become_password(host)
    end

    private def self.cli_become_password(host : Host?) : String?
      return nil unless host
      @@cli_become_passwords[host.name]?
    end

    # Same deprecated-alias rule the connection settings apply (issue #887):
    # ansible resolves each option through a last-entry-wins loop
    # (ConfigManager._loop_entries) over the plugin's flat `vars:` name list
    # against ONE merged task-vars dict, so the LAST listed spelling (e.g.
    # ansible_sudo_pass) wins whenever it is present anywhere - even from a
    # lower-precedence source than a canonical name earlier in the list.
    # Walk the list back to front; within one name the task vars outrank the
    # host's inventory vars (dispatch sites pass the full vars_context, but
    # a few only hold the Host, so both sources are consulted).
    private def self.lookup(keys : Array(String), vars : Hash(String, JSON::Any)?, host : Host?) : String?
      keys.reverse_each do |key|
        [vars.try(&.[key]?), host.try(&.vars[key]?)].each do |value|
          next unless value
          password = value.as_s?
          return password if password && !password.empty?
        end
      end
      nil
    end
  end
end
