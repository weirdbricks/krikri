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
    
    # Create from JSON (for plugin communication)
    def self.from_json(json : JSON::Any) : Host
      Host.new(
        name: json["name"].as_s,
        user: json["user"]?.try(&.as_s),
        port: json["port"]?.try(&.as_i) || 22
      )
    end
  end
end
