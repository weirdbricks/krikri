require "json"
require "digest/md5"
require "colorize"
require "./ssh_manager"
require "./local_executor"
require "./playbook_parser"
require "./inventory_parser"

module CrystalPlay
  # Plugin Manager - Handles plugin execution locally or remotely
  # For remote hosts, uploads plugin binary and executes it there
  class PluginManager
    # Cache of plugins already uploaded to remote hosts
    @@uploaded_plugins = Hash(String, Set(String)).new
    
    # Verbose mode flag
    @@verbose = false
    
    # Set verbose mode
    def self.verbose=(value : Bool)
      @@verbose = value
    end
    
    # Pre-upload all plugins needed for a playbook to all remote hosts
    # This is called once before task execution begins
    # Much more efficient than uploading plugins one at a time during execution
    def self.batch_upload_plugins_for_playbook(
      playbook : Playbook,
      inventory : Inventory
    )
      # Collect all unique module names used in the playbook
      required_plugins = Set(String).new
      
      # Track if any play needs facts gathering
      needs_facts = false
      
      playbook.plays.each do |play|
        # Check if this play gathers facts
        needs_facts = true if play.gather_facts
        
        play.tasks.each do |task|
          # Strip FQCN to get simple plugin name
          simple_name = task.module_name.sub(/^ansible\.(builtin|legacy)\./, "")
          required_plugins.add(simple_name)
        end
        
        play.handlers.each do |handler|
          simple_name = handler.module_name.sub(/^ansible\.(builtin|legacy)\./, "")
          required_plugins.add(simple_name)
        end
      end
      
      # Add facts plugin if any play needs it
      required_plugins.add("facts") if needs_facts
      
      return if required_plugins.empty?
      
      # Collect all unique remote hosts from the playbook
      remote_hosts = [] of Host
      host_keys_seen = Set(String).new
      
      playbook.plays.each do |play|
        hosts = inventory.get_hosts(play.hosts.to_s)
        
        hosts.each do |host|
          # Skip localhost
          next if is_local_connection?(host, host.vars)
          
          # Deduplicate by connection details
          connection_host = get_connection_host(host, host.vars)
          host_key = "#{host.user}@#{connection_host}:#{host.port}"
          
          unless host_keys_seen.includes?(host_key)
            remote_hosts << host
            host_keys_seen.add(host_key)
          end
        end
      end
      
      return if remote_hosts.empty?
      
      puts "Preparing plugins for remote execution...".colorize(:cyan) if @@verbose
      
      # Upload plugins to each unique remote host
      remote_hosts.each do |host|
        upload_plugins_to_host(host, required_plugins.to_a)
      end
      
      puts "" if @@verbose
    end
    
    # Upload a set of plugins to a specific host
    private def self.upload_plugins_to_host(host : Host, plugin_names : Array(String))
      connection_host = get_connection_host(host, host.vars)
      host_key = "#{host.user}@#{connection_host}:#{host.port}"
      
      # Initialize plugin cache for this host
      @@uploaded_plugins[host_key] ||= Set(String).new
      
      remote_plugin_dir = "/tmp/.crystal-play/plugins"
      
      # Create remote plugin directory
      SSHManager.exec(
        connection_host,
        host.user || "root",
        "mkdir -p #{remote_plugin_dir}",
        host.port
      )
      
      # Check which plugins need uploading (check MD5)
      plugins_to_upload = [] of String
      local_plugin_paths = [] of String
      
      plugin_names.each do |plugin_name|
        # Skip if already verified in this session
        next if @@uploaded_plugins[host_key].includes?(plugin_name)
        
        # Get local plugin MD5
        local_plugin_path = get_local_plugin_path(plugin_name)
        local_md5 = Digest::MD5.hexdigest(File.read(local_plugin_path))
        
        # Check if remote plugin exists and matches our MD5
        md5_check = SSHManager.exec(
          connection_host,
          host.user || "root",
          "[ -f #{remote_plugin_dir}/#{plugin_name}.md5 ] && cat #{remote_plugin_dir}/#{plugin_name}.md5",
          host.port
        )
        
        if md5_check[:exit_code] == 0 && md5_check[:stdout].strip == local_md5
          # Plugin exists with matching MD5 - skip upload
          @@uploaded_plugins[host_key].add(plugin_name)
          next
        end
        
        # Plugin needs uploading
        plugins_to_upload << plugin_name
        local_plugin_paths << local_plugin_path
      end
      
      # Nothing to upload
      return if plugins_to_upload.empty?
      
      # Upload plugins in batch
      puts "   → Uploading #{plugins_to_upload.size} plugins to #{connection_host} via rsync".colorize(:cyan) if @@verbose
      
      # Try rsync batch upload first
      if SSHManager.rsync_upload_batch(
        connection_host,
        host.user || "root",
        local_plugin_paths,
        remote_plugin_dir,
        host.port,
        mode: 0o755
      )
        # Rsync succeeded - store MD5s for all plugins
        plugins_to_upload.each do |plugin_name|
          local_plugin_path = get_local_plugin_path(plugin_name)
          local_md5 = Digest::MD5.hexdigest(File.read(local_plugin_path))
          
          # Store MD5 on remote
          SSHManager.exec(
            connection_host,
            host.user || "root",
            "echo '#{local_md5}' > #{remote_plugin_dir}/#{plugin_name}.md5",
            host.port
          )
          
          @@uploaded_plugins[host_key].add(plugin_name)
        end
        
        puts "   ✓ Successfully uploaded #{plugins_to_upload.size} plugins".colorize(:green) if @@verbose
      else
        # Rsync failed - fall back to individual scp uploads
        puts "   → Rsync unavailable, using scp for #{plugins_to_upload.size} plugins".colorize(:yellow) if @@verbose
        
        plugins_to_upload.each_with_index do |plugin_name, index|
          local_plugin_path = get_local_plugin_path(plugin_name)
          remote_plugin_path = "#{remote_plugin_dir}/#{plugin_name}"
          
          # Upload plugin
          SSHManager.upload(
            connection_host,
            host.user || "root",
            local_plugin_path,
            remote_plugin_path,
            host.port,
            mode: 0o755
          )
          
          # Store MD5
          local_md5 = Digest::MD5.hexdigest(File.read(local_plugin_path))
          SSHManager.exec(
            connection_host,
            host.user || "root",
            "echo '#{local_md5}' > #{remote_plugin_path}.md5",
            host.port
          )
          
          @@uploaded_plugins[host_key].add(plugin_name)
        end
        
        puts "   ✓ Uploaded #{plugins_to_upload.size} plugins via scp".colorize(:green) if @@verbose
      end
    end
    
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
      
      # Execute plugin with config via stdin using Process
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      
      begin
        process = Process.new(
          plugin_path,
          input: Process::Redirect::Pipe,
          output: stdout,
          error: stderr
        )
        
        # Write config to stdin
        process.input.print(config.to_json)
        process.input.close
        
        status = process.wait
        output = stdout.to_s
        
        # Try to parse JSON output
        begin
          JSON.parse(output)
        rescue ex
          # Parsing failed - return error with details
          JSON.parse({
            "changed" => false,
            "failed" => true,
            "msg" => "Failed to parse plugin output",
            "stdout" => output,
            "stderr" => stderr.to_s,
            "parse_error" => ex.message
          }.to_json)
        end
      rescue ex
        # Execution failed
        JSON.parse({
          "changed" => false,
          "failed" => true,
          "msg" => "Plugin execution failed: #{ex.message}",
          "stderr" => stderr.to_s
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
      
      # Get remote plugin path
      simple_name = plugin_name.sub(/^ansible\.(builtin|legacy)\./, "")
      remote_plugin_dir = "/tmp/.crystal-play/plugins"
      remote_plugin_path = "#{remote_plugin_dir}/#{simple_name}"
      
      # Modify config to tell plugin it's running locally on the remote
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
