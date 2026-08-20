require "json"

module CrystalPlay
  # Represents a target host for automation
  class Host
    property name : String
    property user : String?
    property port : Int32
    property vars : Hash(String, JSON::Any)
    
    def initialize(@name : String, @user : String? = nil, @port : Int32 = 22)
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
        port: json["port"]?.try(&.as_i?) || 22
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
