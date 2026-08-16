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
    
    # Initialize - ensure control directory exists.
    # Called from exec/exec_script/upload/download/rsync_upload/
    # rsync_upload_batch, i.e. once per SSH operation, for a directory
    # that only ever needs creating once - so the Dir.exists? stat is
    # guarded by a flag rather than re-run every time.
    @@control_dir_ready = false

    def self.init
      return if @@control_dir_ready
      Dir.mkdir_p(@@control_path_dir) unless Dir.exists?(@@control_path_dir)
      @@control_dir_ready = true
    end
    
    # Get connection pool statistics
    def self.stats : Hash(String, Int32)
      @@stats
    end
    
    # Runs *block* (given the just-spawned *process*) on a separate fiber
    # and bounds it to *timeout_seconds* wall-clock time - both `exec`
    # and `exec_script` accepted a `timeout:` parameter that was never
    # actually enforced anywhere, leaving every blocking Process call
    # (`#wait`, and for exec_script, the write of a potentially large
    # script into the process's own stdin pipe) able to hang forever
    # with no escape hatch at all. `-o ServerAliveInterval=`/
    # `ServerAliveCountMax=` only bound an *established* SSH session
    # going idle - they do nothing for a local pipe write blocking
    # because nothing is reading the other end (the remote host went
    # unreachable mid-handshake, before ssh itself even started
    # forwarding stdin), which is a local blocking syscall the SSH
    # protocol's own keepalive machinery never sees. Found running
    # konstruktoid-hardening's newly-batched (0.9.155) 411-item "Find
    # possible suid binaries" step: the whole crystal-ansible process
    # sat silent, producing no further output and no error, until an
    # *external* `timeout` wrapper eventually killed it - a real host/
    # network hang, not a task bug, and previously nothing inside
    # crystal-ansible itself could ever recover from it.
    #
    # On timeout, SIGKILLs the process and gives it a further 5s to
    # actually exit and report a status before giving up entirely (a
    # hard bound of its own, in case even the kill signal doesn't
    # unblock the fiber - e.g. if it's wedged in kernel-level uninter-
    # ruptible I/O, vanishingly rare but not impossible).
    private def self.run_with_timeout(
      process : Process,
      timeout_seconds : Int32,
      &block : Process -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)
    ) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      channel = Channel(NamedTuple(exit_code: Int32, stdout: String, stderr: String)).new(1)

      spawn do
        result = begin
          block.call(process)
        rescue ex
          {exit_code: 255, stdout: "", stderr: "SSH execution failed: #{ex.message}"}
        end
        channel.send(result)
      end

      select
      when result = channel.receive
        result
      when timeout(timeout_seconds.seconds)
        begin
          process.terminate(graceful: false)
        rescue
        end
        select
        when result = channel.receive
          result
        when timeout(5.seconds)
          {exit_code: 255, stdout: "", stderr: "SSH command timed out after #{timeout_seconds}s (host likely unreachable) and did not exit even after being killed"}
        end
      end
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
      timeout : Int32 = 300,
      identity_file : String? = nil
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
      ] + identity_args(identity_file) + [
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

        run_with_timeout(process, timeout) do |proc|
          status = proc.wait
          {
            exit_code: status.exit_code,
            stdout: stdout.to_s,
            stderr: stderr.to_s,
          }
        end
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
      timeout : Int32 = 300,
      identity_file : String? = nil
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
      ] + identity_args(identity_file) + [
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

        run_with_timeout(process, timeout) do |proc|
          proc.input.print(script)
          proc.input.close

          status = proc.wait
          {
            exit_code: status.exit_code,
            stdout: stdout.to_s,
            stderr: stderr.to_s,
          }
        end
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
      mode : Int32? = 0o644,
      identity_file : String? = nil,
      recursive : Bool = false
    )
      init
      @@stats["files_uploaded"] += 1

      unless recursive ? Dir.exists?(local_path) : File.exists?(local_path)
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
      ] + (recursive ? ["-r"] : [] of String) + identity_args(identity_file) + [
        "-P", port.to_s,
        local_path,
        "#{user}@#{host}:#{remote_path}"
      ]

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = Process.run(
        scp_cmd[0],
        scp_cmd[1..],
        output: out_io,
        error: err_io
      )

      unless result.exit_code == 0
        detail = (err_io.to_s + out_io.to_s).strip
        detail = detail.empty? ? "no output" : detail
        raise "Failed to upload #{local_path} to #{host}:#{remote_path}: #{detail}"
      end

      # Set permissions if different from default. Pass `mode: nil` to
      # suppress this entirely when the caller is uploading a batch of
      # files and can fold one chmod into a round trip it already makes -
      # otherwise this costs an extra round trip *per file*.
      if mode && mode != 0o644
        exec(host, user, "chmod #{mode.to_s(8)} #{remote_path}", port, identity_file: identity_file)
      end
    end

    # Download file from remote host via SCP
    def self.download(
      host : String,
      user : String,
      remote_path : String,
      local_path : String,
      port : Int32 = 22,
      identity_file : String? = nil
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
      ] + identity_args(identity_file) + [
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
      mode : Int32 = 0o644,
      identity_file : String? = nil
    ) : Bool
      init

      return false unless rsync_available?

      control_path = get_control_path(host, user, port)

      # Use rsync with SSH control master
      rsync_cmd = [
        "rsync",
        "-az",  # archive mode, compress
        "--chmod=#{mode.to_s(8)}",  # set permissions
        "-e", "ssh -o ControlMaster=auto -o ControlPath=#{control_path} -o ControlPersist=600 -o StrictHostKeyChecking=accept-new#{identity_ssh_opt(identity_file)} -p #{port}",
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
      mode : Int32 = 0o755,
      identity_file : String? = nil
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
        "-e", "ssh -o ControlMaster=auto -o ControlPath=#{control_path} -o ControlPersist=600 -o StrictHostKeyChecking=accept-new#{identity_ssh_opt(identity_file)} -p #{port}",
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
    
    # Memoized per (host, user, port) - the gsub-over-a-regex result never
    # changes for the same triple, and every exec/upload/download/rsync
    # call on a host recomputes it.
    @@control_path_cache = Hash({String, String, Int32}, String).new

    # Get control socket path for connection pooling
    private def self.get_control_path(host : String, user : String, port : Int32) : String
      @@control_path_cache.fetch({host, user, port}) do
        # Create a unique socket path for this connection
        # Format: /tmp/.crystal-play-ssh/user@host:port
        socket_name = "#{user}@#{host}:#{port}".gsub(/[^a-zA-Z0-9@:.-]/, "_")
        @@control_path_cache[{host, user, port}] = "#{@@control_path_dir}/#{socket_name}"
      end
    end
    
    # `-i <path>` args for ssh/scp when the inventory specifies
    # ansible_ssh_private_key_file - omitted entirely so ssh falls back to
    # its own default identities/agent, matching real Ansible/OpenSSH
    # behavior when no key is given.
    private def self.identity_args(identity_file : String?) : Array(String)
      identity_file ? ["-i", identity_file] : [] of String
    end

    # Same as identity_args, but as a string fragment for rsync's `-e`
    # ssh command line (which is a single shell-quoted string, not an
    # argv array).
    private def self.identity_ssh_opt(identity_file : String?) : String
      identity_file ? " -i #{shell_quote(identity_file)}" : ""
    end

    # Properly quote a string for shell execution
    # Uses single quotes and escapes any single quotes in the string
    private def self.shell_quote(str : String) : String
      "'#{str.gsub("'", "'\\''")}'"
    end
  end
end
