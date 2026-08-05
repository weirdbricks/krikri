require "process"
require "file_utils"

# SSH Manager - CLI-based implementation
# Uses native SSH command with ControlMaster for connection pooling
module CrystalPlay
  class SSHManager
    # Control socket directory
    @@control_path_dir = "/tmp/.crystal-play-ssh"
    
    # Connection pool statistics
    @@stats = {
      "connections_created" => 0,
      "connections_reused" => 0,
      "commands_executed" => 0,
      "files_uploaded" => 0,
      "files_downloaded" => 0
    }
    
    # Initialize - ensure control directory exists
    def self.init
      Dir.mkdir_p(@@control_path_dir) unless Dir.exists?(@@control_path_dir)
    end
    
    # Get connection pool statistics
    def self.stats : Hash(String, Int32)
      @@stats
    end
    
    # Reset statistics
    def self.reset_stats
      @@stats.each_key do |key|
        @@stats[key] = 0
      end
    end
    
    # Execute command on remote host
    def self.exec(
      host : String,
      user : String,
      command : String,
      port : Int32 = 22,
      timeout : Int32 = 300
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      
      init
      @@stats["commands_executed"] += 1
      
      # Build SSH command with ControlMaster for connection pooling
      control_path = get_control_path(host, user, port)
      
      # Important: We pass the command through bash -c to ensure proper shell
      # interpretation on the remote side. This prevents the local shell from
      # interpreting operators like ||, &&, |, >, etc.
      # We use /bin/bash instead of /bin/sh for better compatibility
      wrapped_command = "/bin/bash -c #{shell_quote(command)}"
      
      ssh_cmd = [
        "ssh",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",  # Keep connection alive for 10 minutes
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",  # Auto-accept new host keys
        "-p", port.to_s,
        "#{user}@#{host}",
        wrapped_command
      ]
      
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      
      begin
        process = Process.new(
          ssh_cmd[0],
          ssh_cmd[1..],
          output: stdout,
          error: stderr
        )
        
        status = process.wait
        
        {
          exit_code: status.exit_code,
          stdout: stdout.to_s,
          stderr: stderr.to_s
        }
      rescue ex
        {
          exit_code: 255,
          stdout: "",
          stderr: "SSH execution failed: #{ex.message}"
        }
      end
    end

    # Runs *script* on the remote host via `ssh ... bash -s`, piped over
    # that single invocation's own stdin - used by TaskExecutor's batch
    # path (batching, on by default; --no-batching disables it) to run
    # several plugin invocations
    # in one SSH round trip. Deliberately separate from `exec`: `exec`
    # wraps a command through `bash -c <string>`, which has no stdin of
    # its own to carry a whole script through; this uses `bash -s`
    # (reads its script from stdin) specifically so the caller can hand
    # over a multi-step script without needing to escape it into a
    # single command-line string.
    def self.exec_script(
      host : String,
      user : String,
      script : String,
      port : Int32 = 22,
      timeout : Int32 = 300
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      init
      @@stats["commands_executed"] += 1

      control_path = get_control_path(host, user, port)

      ssh_cmd = [
        "ssh",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
        "-p", port.to_s,
        "#{user}@#{host}",
        "bash", "-s",
      ]

      stdout = IO::Memory.new
      stderr = IO::Memory.new

      begin
        process = Process.new(
          ssh_cmd[0],
          ssh_cmd[1..],
          input: Process::Redirect::Pipe,
          output: stdout,
          error: stderr
        )

        process.input.print(script)
        process.input.close

        status = process.wait

        {
          exit_code: status.exit_code,
          stdout: stdout.to_s,
          stderr: stderr.to_s,
        }
      rescue ex
        {
          exit_code: 255,
          stdout: "",
          stderr: "SSH script execution failed: #{ex.message}",
        }
      end
    end
    
    # Upload file to remote host via SCP
    def self.upload(
      host : String,
      user : String,
      local_path : String,
      remote_path : String,
      port : Int32 = 22,
      mode : Int32 = 0o644
    )
      init
      @@stats["files_uploaded"] += 1
      
      unless File.exists?(local_path)
        raise "Local file not found: #{local_path}"
      end
      
      control_path = get_control_path(host, user, port)
      
      # Use scp with ControlMaster to reuse SSH connection
      scp_cmd = [
        "scp",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "StrictHostKeyChecking=accept-new",
        "-P", port.to_s,
        local_path,
        "#{user}@#{host}:#{remote_path}"
      ]
      
      result = Process.run(
        scp_cmd[0],
        scp_cmd[1..],
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )
      
      unless result.exit_code == 0
        raise "Failed to upload #{local_path} to #{host}:#{remote_path}"
      end
      
      # Set permissions if different from default
      if mode != 0o644
        exec(host, user, "chmod #{mode.to_s(8)} #{remote_path}", port)
      end
    end
    
    # Download file from remote host via SCP
    def self.download(
      host : String,
      user : String,
      remote_path : String,
      local_path : String,
      port : Int32 = 22
    )
      init
      @@stats["files_downloaded"] += 1
      
      control_path = get_control_path(host, user, port)
      
      # Use scp with ControlMaster to reuse SSH connection
      scp_cmd = [
        "scp",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=#{control_path}",
        "-o", "ControlPersist=600",
        "-o", "StrictHostKeyChecking=accept-new",
        "-P", port.to_s,
        "#{user}@#{host}:#{remote_path}",
        local_path
      ]
      
      result = Process.run(
        scp_cmd[0],
        scp_cmd[1..],
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )
      
      unless result.exit_code == 0
        raise "Failed to download #{host}:#{remote_path} to #{local_path}"
      end
    end
    
    # Whether the `rsync` binary is available locally. Resolved once per
    # process (a `which rsync` spawn per call was pure overhead - rsync
    # availability doesn't change mid-run).
    @@rsync_available : Bool? = nil

    private def self.rsync_available? : Bool
      cached = @@rsync_available
      return cached unless cached.nil?

      result = Process.run("which", ["rsync"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      @@rsync_available = result.exit_code == 0
    end

    # Upload file using rsync (more efficient for incremental updates)
    # Returns true if successful, false if rsync not available or failed
    def self.rsync_upload(
      host : String,
      user : String,
      local_path : String,
      remote_path : String,
      port : Int32 = 22,
      mode : Int32 = 0o644
    ) : Bool
      init

      return false unless rsync_available?

      control_path = get_control_path(host, user, port)
      
      # Use rsync with SSH control master
      rsync_cmd = [
        "rsync",
        "-az",  # archive mode, compress
        "--chmod=#{mode.to_s(8)}",  # set permissions
        "-e", "ssh -o ControlMaster=auto -o ControlPath=#{control_path} -o ControlPersist=600 -o StrictHostKeyChecking=accept-new -p #{port}",
        local_path,
        "#{user}@#{host}:#{remote_path}"
      ]
      
      result = Process.run(
        rsync_cmd[0],
        rsync_cmd[1..],
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )
      
      if result.exit_code == 0
        @@stats["files_uploaded"] += 1
        true
      else
        false
      end
    end
    
    # Batch upload multiple files using rsync (most efficient)
    # Returns true if successful, false if rsync not available or failed
    def self.rsync_upload_batch(
      host : String,
      user : String,
      local_files : Array(String),
      remote_dir : String,
      port : Int32 = 22,
      mode : Int32 = 0o755
    ) : Bool
      init

      return false if local_files.empty?
      return false unless rsync_available?

      control_path = get_control_path(host, user, port)

      # rsync accepts multiple sources for one destination directory
      # natively - one process spawn (and one SSH session) for the whole
      # batch instead of one per file.
      rsync_cmd = [
        "rsync",
        "-az",
        "--chmod=#{mode.to_s(8)}",
        "-e", "ssh -o ControlMaster=auto -o ControlPath=#{control_path} -o ControlPersist=600 -o StrictHostKeyChecking=accept-new -p #{port}",
      ] + local_files + ["#{user}@#{host}:#{remote_dir}/"]

      result = Process.run(
        rsync_cmd[0],
        rsync_cmd[1..],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      if result.exit_code == 0
        @@stats["files_uploaded"] += local_files.size
        true
      else
        false
      end
    end
    
    # Close specific connection
    def self.close_connection(host : String, user : String, port : Int32 = 22)
      control_path = get_control_path(host, user, port)
      
      # Send exit command to close the master connection
      if File.exists?(control_path)
        Process.run(
          "ssh",
          ["-o", "ControlPath=#{control_path}", "-O", "exit", "#{user}@#{host}"],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        )
        
        # Clean up socket file
        File.delete(control_path) if File.exists?(control_path)
      end
    end
    
    # Close all connections
    def self.close_all
      return unless Dir.exists?(@@control_path_dir)
      
      # Remove all control sockets
      Dir.glob("#{@@control_path_dir}/*").each do |socket_path|
        File.delete(socket_path) if File.exists?(socket_path)
      end
    end
    
    # Get control socket path for connection pooling
    private def self.get_control_path(host : String, user : String, port : Int32) : String
      # Create a unique socket path for this connection
      # Format: /tmp/.crystal-play-ssh/user@host:port
      socket_name = "#{user}@#{host}:#{port}".gsub(/[^a-zA-Z0-9@:.-]/, "_")
      "#{@@control_path_dir}/#{socket_name}"
    end
    
    # Properly quote a string for shell execution
    # Uses single quotes and escapes any single quotes in the string
    private def self.shell_quote(str : String) : String
      "'#{str.gsub("'", "'\\''")}'"
    end
  end
end
