require "json"
require "digest/md5"
require "colorize"
require "./ssh_manager"
require "./local_executor"

module CrystalPlay
  # Plugin Manager - Handles plugin execution locally or remotely
  # For remote hosts, uploads plugin binary and executes it there
  class PluginManager
    # Cache of plugins already uploaded to remote hosts
    @@uploaded_plugins = Hash(String, Set(String)).new
    
    # Execute a plugin on a host (local or remote)
    def self.execute_plugin(
      plugin_name : String,
      config : JSON::Any,
      host : Host,
      vars : Hash(String, JSON::Any)
    ) : JSON::Any
      
      # Check if this is a local connection
      is_local = is_local_connection?(host, vars)
      
      if is_local
        execute_local_plugin(plugin_name, config)
      else
        execute_remote_plugin(plugin_name, config, host, vars)
      end
    end
    
    # Execute plugin locally
    private def self.execute_local_plugin(plugin_name : String, config : JSON::Any) : JSON::Any
      plugin_path = get_local_plugin_path(plugin_name)
      
      # Execute plugin with config via stdin
      output = `echo '#{config.to_json}' | #{plugin_path} 2>&1`
      
      begin
        JSON.parse(output)
      rescue
        # If parsing fails, return error
        JSON.parse({
          "changed" => false,
          "failed" => true,
          "msg" => "Failed to parse plugin output",
          "stdout" => output
        }.to_json)
      end
    end
    
    # Execute plugin remotely (uploads if needed, then runs)
    private def self.execute_remote_plugin(
      plugin_name : String,
      config : JSON::Any,
      host : Host,
      vars : Hash(String, JSON::Any)
    ) : JSON::Any
      
      # Get the actual connection host (checks ansible_host)
      connection_host = get_connection_host(host, vars)
      
      # Ensure plugin is uploaded to remote
      remote_plugin_path = ensure_plugin_uploaded(plugin_name, host, vars)
      
      # Modify config to tell plugin it's running locally on the remote
      # The plugin needs to know it should execute commands locally, not via SSH
      config_hash = JSON.parse(config.to_json).as_h
      if config_hash["vars"]?
        vars_hash = config_hash["vars"].as_h
        vars_hash["ansible_connection"] = JSON::Any.new("local")
        config_hash["vars"] = JSON::Any.new(vars_hash)
      else
        config_hash["vars"] = JSON::Any.new({"ansible_connection" => JSON::Any.new("local")})
      end
      modified_config = JSON::Any.new(config_hash)
      
      # Execute plugin remotely with modified config via stdin
      command = "echo '#{modified_config.to_json.gsub("'", "'\\''")}' | #{remote_plugin_path}"
      result = SSHManager.exec(
        connection_host,
        host.user || "root",
        command,
        host.port
      )
      
      if result[:exit_code] != 0
        return JSON.parse({
          "changed" => false,
          "failed" => true,
          "msg" => "Plugin execution failed on remote",
          "stdout" => result[:stdout],
          "stderr" => result[:stderr]
        }.to_json)
      end
      
      begin
        JSON.parse(result[:stdout])
      rescue
        JSON.parse({
          "changed" => false,
          "failed" => true,
          "msg" => "Failed to parse plugin output from remote",
          "stdout" => result[:stdout],
          "stderr" => result[:stderr]
        }.to_json)
      end
    end
    
    # Ensure plugin binary is uploaded to remote host
    # Uses MD5 checksum to detect if plugin changed
    private def self.ensure_plugin_uploaded(
      plugin_name : String,
      host : Host,
      vars : Hash(String, JSON::Any)
    ) : String
      
      # Get the actual connection host (checks ansible_host)
      connection_host = get_connection_host(host, vars)
      
      # Strip FQCN to get simple plugin name
      simple_name = plugin_name.sub(/^ansible\.(builtin|legacy)\./, "")
      
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      
      # Check if already uploaded in this session
      @@uploaded_plugins[host_key] ||= Set(String).new
      
      remote_plugin_dir = "/tmp/.crystal-play/plugins"
      remote_plugin_path = "#{remote_plugin_dir}/#{simple_name}"  # Use simple name for remote path
      
      # If we've already verified in this session, skip (no output needed)
      if @@uploaded_plugins[host_key].includes?(simple_name)
        return remote_plugin_path
      end
      
      # Get local plugin MD5
      local_plugin_path = get_local_plugin_path(plugin_name)
      local_md5 = Digest::MD5.hexdigest(File.read(local_plugin_path))
      
      # Check if remote plugin exists and matches our MD5
      # Store MD5 in companion file: /tmp/.crystal-play/plugins/copy.md5
      md5_check = SSHManager.exec(
        connection_host,
        host.user || "root",
        "[ -f #{remote_plugin_path}.md5 ] && cat #{remote_plugin_path}.md5",
        host.port
      )
      
      if md5_check[:exit_code] == 0 && md5_check[:stdout].strip == local_md5
        # Plugin exists with matching MD5 - reuse it!
        print "   → Plugin '#{simple_name}' already on #{connection_host} (MD5 match)".colorize(:cyan)
        puts ""
        @@uploaded_plugins[host_key].add(simple_name)
        return remote_plugin_path
      end
      
      # Plugin doesn't exist or is outdated - upload it
      if md5_check[:exit_code] == 0
        # Plugin exists but MD5 differs
        print "   → Uploading plugin '#{simple_name}' to #{connection_host} (MD5 mismatch - updating)".colorize(:yellow)
      else
        # Plugin doesn't exist
        print "   → Uploading plugin '#{simple_name}' to #{connection_host} (first time)".colorize(:green)
      end
      puts ""
      
      # Create remote plugin directory
      SSHManager.exec(
        connection_host,
        host.user || "root",
        "mkdir -p #{remote_plugin_dir}",
        host.port
      )
      
      # Upload plugin binary
      SSHManager.upload(
        connection_host,
        host.user || "root",
        local_plugin_path,
        remote_plugin_path,
        host.port,
        mode: 0o755  # Make executable
      )
      
      # Store MD5 for future checks
      SSHManager.exec(
        connection_host,
        host.user || "root",
        "echo '#{local_md5}' > #{remote_plugin_path}.md5",
        host.port
      )
      
      # Mark as uploaded
      @@uploaded_plugins[host_key].add(simple_name)
      
      remote_plugin_path
    end
    
    # Get local plugin path (compiled binary)
    private def self.get_local_plugin_path(plugin_name : String) : String
      # Strip FQCN to get simple plugin filename
      simple_name = plugin_name.sub(/^ansible\.(builtin|legacy)\./, "")
      
      # Try compiled plugin
      compiled = "./bin/plugins/#{simple_name}"
      return compiled if File.exists?(compiled)
      
      raise "Plugin binary not found: #{plugin_name} (looked for #{compiled})"
    end
    
    # Check if connection is local
    private def self.is_local_connection?(host : Host, vars : Hash(String, JSON::Any)) : Bool
      # Check if ansible_connection is set to local
      if conn = vars["ansible_connection"]?
        return conn.as_s? == "local"
      end
      
      # Check if host is localhost
      host.name == "localhost"
    end
    
    # Get the actual hostname to connect to (checks ansible_host variable)
    private def self.get_connection_host(host : Host, vars : Hash(String, JSON::Any)) : String
      # Check for ansible_host variable (overrides inventory hostname)
      if ansible_host = vars["ansible_host"]?
        return ansible_host.as_s
      end
      
      # Fall back to inventory hostname
      host.name
    end
    
    # Clear uploaded plugins cache (for testing)
    def self.clear_cache
      @@uploaded_plugins.clear
    end
  end
end
