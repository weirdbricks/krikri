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

    # Task-level *vars* first (Ansible's task-var precedence over inventory),
    # then the host's own inventory vars - dispatch sites pass the full
    # vars_context, but a couple (batch daemon routing, the async launch
    # builder) only hold the Host, so both sources are consulted.
    def self.connection(vars : Hash(String, JSON::Any)?, host : Host? = nil) : String?
      lookup(CONNECTION_KEYS, vars, host)
    end

    def self.become(vars : Hash(String, JSON::Any)?, host : Host? = nil) : String?
      lookup(BECOME_KEYS, vars, host)
    end

    private def self.lookup(keys : Array(String), vars : Hash(String, JSON::Any)?, host : Host?) : String?
      keys.each do |key|
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
