#!/usr/bin/env crystal

require "json"
require "./ssh_manager"

module CrystalPlay
  # Host information
  class Host
    property name : String
    property user : String?
    property port : Int32
    
    def initialize(@name, @user = nil, @port = 22)
    end
    
    def self.from_json(json : JSON::Any) : Host
      Host.new(
        name: json["name"].as_s,
        user: json["user"]?.try(&.as_s),
        port: json["port"]?.try(&.as_i) || 22
      )
    end
  end
  
  # Plugin result structure with diff support
  class PluginResult
    property changed : Bool
    property failed : Bool
    property msg : String
    property diff : JSON::Any?
    property extra : Hash(String, JSON::Any)
    
    def initialize(
      changed : Bool,
      failed : Bool,
      msg : String,
      diff : JSON::Any? = nil,
      **kwargs
    )
      @changed = changed
      @failed = failed
      @msg = msg
      @diff = diff
      @extra = Hash(String, JSON::Any).new
      kwargs.each do |key, value|
        @extra[key.to_s] = JSON.parse(value.to_json)
      end
    end
    
    def to_json(io : IO)
      result = Hash(String, JSON::Any::Type).new
      result["changed"] = @changed
      result["failed"] = @failed
      result["msg"] = @msg
      
      # Add diff if present
      if diff = @diff
        result["diff"] = diff.raw  # Extract the raw value from JSON::Any
      end
      
      # Add extra fields
      @extra.each do |key, value|
        result[key] = value.raw  # Extract the raw value from JSON::Any
      end
      
      result.to_json(io)
    end
  end
  
  # Base class for all plugins
  abstract class BasePlugin
    property host : Host
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    property config : JSON::Any
    property diff_mode : Bool
    
    def initialize(@config : JSON::Any)
      @host = Host.from_json(@config["host"])
      
      # Parse params
      @params = Hash(String, String).new
      if params_json = @config["params"]?
        params_json.as_h.each do |key, value|
          @params[key] = value.to_s
        end
      end
      
      # Parse vars
      @vars = Hash(String, JSON::Any).new
      if vars_json = @config["vars"]?
        vars_json.as_h.each do |key, value|
          @vars[key] = value
        end
      end
      
      # Check for diff mode
      @diff_mode = is_true?(@params["diff_mode"]?)
    end
    
    # Abstract method - must be implemented by subclasses
    abstract def execute : PluginResult
    
    # Run the plugin and output JSON result
    def run
      begin
        result = execute
        puts result.to_json
      rescue ex
        error_result = PluginResult.new(
          changed: false,
          failed: true,
          msg: "Plugin execution failed: #{ex.message}"
        )
        puts error_result.to_json
        STDERR.puts ex.backtrace.join("\n")
      end
    end
    
    # Helper methods for remote execution
    # Uses SSHManager for real SSH connections with connection pooling
    
    protected def remote_exec(command : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      SSHManager.exec(
        @host.name,
        @host.user || "root",
        command,
        @host.port
      )
    end
    
    protected def remote_upload(local_path : String, remote_path : String)
      SSHManager.upload(
        @host.name,
        @host.user || "root",
        local_path,
        remote_path,
        @host.port
      )
    end
    
    protected def remote_download(remote_path : String, local_path : String)
      SSHManager.download(
        @host.name,
        @host.user || "root",
        remote_path,
        local_path,
        @host.port
      )
    end
    
    protected def remote_file_exists?(path : String) : Bool
      result = remote_exec("test -f #{path}")
      result[:exit_code] == 0
    end
    
    protected def remote_dir_exists?(path : String) : Bool
      result = remote_exec("test -d #{path}")
      result[:exit_code] == 0
    end
    
    # Helper to check if a parameter is truthy
    protected def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
    
    # Generate unified diff
    protected def generate_unified_diff(before : String, after : String, before_header : String = "before", after_header : String = "after") : JSON::Any
      JSON.parse({
        "before" => before,
        "after" => after,
        "before_header" => before_header,
        "after_header" => after_header
      }.to_json)
    end
    
    # Generate attribute diff
    protected def generate_attribute_diff(before : Hash(String, String), after : Hash(String, String)) : JSON::Any
      JSON.parse({
        "before" => before,
        "after" => after
      }.to_json)
    end
  end
end
