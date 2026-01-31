require "json"

module CrystalPlay
  # SSH Configuration
  # Manages SSH settings, keys, and connection preferences
  class SSHConfig
    property default_user : String
    property default_port : Int32
    property connection_timeout : Int32
    property command_timeout : Int32
    property key_paths : Array(String)
    property known_hosts_path : String
    property host_key_checking : Bool
    property control_persist : Int32
    property max_connections : Int32
    property ssh_args : Array(String)
    
    def initialize
      @default_user = ENV["USER"]? || "root"
      @default_port = 22
      @connection_timeout = 10  # seconds
      @command_timeout = 300    # seconds (5 minutes)
      @host_key_checking = true
      @control_persist = 600    # seconds (10 minutes)
      @max_connections = 50
      @ssh_args = [] of String
      
      # Default SSH key paths (in order of preference)
      @key_paths = [
        "#{home}/.ssh/id_ed25519",
        "#{home}/.ssh/id_rsa",
        "#{home}/.ssh/id_ecdsa",
        "#{home}/.ssh/id_dsa"
      ]
      
      @known_hosts_path = "#{home}/.ssh/known_hosts"
    end
    
    # Load configuration from file
    def self.load(path : String) : SSHConfig
      config = new
      
      if File.exists?(path)
        data = JSON.parse(File.read(path))
        
        config.default_user = data["default_user"]?.try(&.as_s) || config.default_user
        config.default_port = data["default_port"]?.try(&.as_i) || config.default_port
        config.connection_timeout = data["connection_timeout"]?.try(&.as_i) || config.connection_timeout
        config.command_timeout = data["command_timeout"]?.try(&.as_i) || config.command_timeout
        config.host_key_checking = data["host_key_checking"]?.try(&.as_bool) || config.host_key_checking
        
        if key_paths = data["key_paths"]?.try(&.as_a)
          config.key_paths = key_paths.map(&.as_s)
        end
      end
      
      config
    end
    
    # Save configuration to file
    def save(path : String)
      data = {
        "default_user" => @default_user,
        "default_port" => @default_port,
        "connection_timeout" => @connection_timeout,
        "command_timeout" => @command_timeout,
        "host_key_checking" => @host_key_checking,
        "key_paths" => @key_paths
      }
      
      File.write(path, data.to_pretty_json)
    end
    
    # Get available SSH keys
    def available_keys : Array(String)
      @key_paths.select { |path| File.exists?(path) }
    end
    
    # Check if SSH key exists
    def key_exists?(path : String) : Bool
      File.exists?(path) && File.exists?("#{path}.pub")
    end
    
    # Get SSH config file path
    def ssh_config_path : String
      "#{home}/.ssh/config"
    end
    
    # Parse SSH config file for host settings
    def parse_ssh_config(host : String) : Hash(String, String)
      config = {} of String => String
      config_path = ssh_config_path
      
      return config unless File.exists?(config_path)
      
      in_host_block = false
      current_host = ""
      
      File.read_lines(config_path).each do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        
        if line.downcase.starts_with?("host ")
          host_pattern = line.split(/\s+/, 2)[1]
          in_host_block = matches_host_pattern?(host, host_pattern)
          current_host = host_pattern
        elsif in_host_block
          parts = line.split(/\s+/, 2)
          next if parts.size < 2
          
          key = parts[0].downcase
          value = parts[1]
          
          config[key] = value
        end
      end
      
      config
    end
    
    # Get home directory
    private def home : String
      ENV["HOME"]? || ENV["USERPROFILE"]? || "~"
    end
    
    # Match host against SSH config pattern
    private def matches_host_pattern?(host : String, pattern : String) : Bool
      # Simple pattern matching (can be enhanced with wildcards)
      if pattern == "*"
        return true
      end
      
      if pattern.includes?("*")
        # Convert SSH pattern to regex
        regex_pattern = pattern.gsub("*", ".*")
        return !!(host =~ /^#{regex_pattern}$/)
      end
      
      host == pattern
    end
  end
  
  # Host-specific SSH configuration
  class HostSSHConfig
    property hostname : String?
    property port : Int32?
    property user : String?
    property identity_file : String?
    property proxy_jump : String?
    property forward_agent : Bool?
    
    def initialize
      @hostname = nil
      @port = nil
      @user = nil
      @identity_file = nil
      @proxy_jump = nil
      @forward_agent = nil
    end
    
    def self.from_ssh_config(config : Hash(String, String)) : HostSSHConfig
      host_config = new
      
      host_config.hostname = config["hostname"]?
      host_config.port = config["port"]?.try(&.to_i)
      host_config.user = config["user"]?
      host_config.identity_file = config["identityfile"]?
      host_config.proxy_jump = config["proxyjump"]?
      host_config.forward_agent = config["forwardagent"]? == "yes"
      
      host_config
    end
  end
end
