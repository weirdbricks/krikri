require "json"

module Krikri
  # Represents a target host for automation
  class Host
    property name : String
    property user : String?
    # nil means "the user never specified a port" - not the same thing as
    # port 22. Only an explicit `ansible_port` (inventory/CLI) sets this;
    # when nil, SSHManager omits `-p` entirely so ssh's own resolution
    # (~/.ssh/config Port directives, /etc/ssh/ssh_config) takes over,
    # matching real Ansible's ssh connection plugin. An explicit port
    # still overrides ssh's config exactly as `-p` always has.
    property port : Int32?
    property vars : Hash(String, JSON::Any)

    def initialize(@name : String, @user : String? = nil, @port : Int32? = nil)
      @vars = Hash(String, JSON::Any).new
    end

    # Create from JSON (for plugin communication). Uses the `?` variants
    # (as_s?/as_i?) rather than `.try(&.as_s)`: `try` only guards against a
    # missing key (Crystal nil), not a key present with a JSON `null`
    # value - `{"user": null}.try(&.as_s)` still raises, since the JSON::Any
    # itself is non-nil even though it wraps null. A host declared without
    # an explicit user (e.g. `localhost ansible_connection=local`, with no
    # ansible_user=) serializes exactly that way.
    def self.from_json(json : JSON::Any) : Host
      Host.new(
        name: json["name"].as_s,
        user: json["user"]?.try(&.as_s?),
        # JSON null (an un-set port serialized from a nilable Host) stays
        # nil - same tri-state as the property above.
        port: json["port"]?.try(&.as_i?)
      )
    end

    # The address the SSH/transport layer actually connects to — either
    # `ansible_host` (if set in the inventory) or the inventory hostname.
    # Used for display and connection routing throughout the codebase.
    def connection_host : String
      @vars["ansible_host"]?.try(&.as_s?) || @name
    end
  end
end
