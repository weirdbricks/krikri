require "json"
require "./variable_substitutor"

module Krikri
  # ansible-core's `admin_users` shell option: the users the controller
  # expects to have admin privileges, which decides HOW it shares its
  # temporary files with a become_user (action/__init__.py's
  # _fixup_perms2). Its only observable consequence is the wording of the
  # failure when that sharing is impossible: a connection user IN this list
  # gets "Failed to change ownership of the temporary files ...", anyone
  # else the file-mode/ACL fallback's message (issue #1972 - the round's
  # Rocky target was reached as root, in the default list).
  #
  # The option is a list of names, settable as the `ansible_admin_users`
  # variable (flat or YAML/JSON list) and defaulting to root/toor, so a
  # play that names its own admin user changes the failure ansible prints;
  # krikri has to read the same list or it words the same task differently.
  module AdminUsers
    DEFAULT = ["root", "toor"]

    # The effective list for one task: its own vars context first (already
    # merged over the host's inventory vars by the caller), then the host's
    # raw inventory vars - the same two tiers ConnectionSettings uses for
    # the connection variables a task can override.
    def self.resolve(vars : Hash(String, JSON::Any)?, host_vars : Hash(String, JSON::Any)?) : Array(String)
      raw = vars.try(&.["ansible_admin_users"]?) || host_vars.try(&.["ansible_admin_users"]?)
      return DEFAULT if raw.nil?
      parse(render(raw, vars))
    end

    # A list lands as a real array (JSON/YAML inventory), a Python repr
    # ("['root', 'toor']", what a Jinja expression renders to) through
    # parse_json_or_python_literal, and a bare "root,toor" string by
    # splitting it the way ansible's list-type option coerces a string.
    def self.parse(value : JSON::Any) : Array(String)
      raw = value.as_a? ? value : Krikri.parse_json_or_python_literal(value.as_s? || "")
      if list = raw.as_a?
        return list.compact_map(&.as_s?).reject(&.empty?)
      end
      users = (raw.as_s? || "").split(',').map(&.strip).reject(&.empty?)
      users.empty? ? DEFAULT : users
    end

    # Whether *user* belongs to *users*: the predicate _fixup_perms2 asks
    # before it raises its chown failure.
    def self.admin?(users : Array(String), user : String?) : Bool
      !user.nil? && users.includes?(user)
    end

    # A templated `ansible_admin_users` (e.g. "{{ [lookup('env', 'USER')] }}")
    # renders against the task's context exactly like every other var.
    private def self.render(raw : JSON::Any, vars : Hash(String, JSON::Any)?) : JSON::Any
      text = raw.as_s?
      return raw if text.nil? || vars.nil? || !text.includes?("{{")
      rendered = VarSubstitutor.new(vars: vars).strict_render(text)
      Krikri.parse_json_or_python_literal(rendered)
    rescue
      raw
    end
  end
end
