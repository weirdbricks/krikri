#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Copy plugin - copies files to remote locations
  # Compatible with Ansible's ansible.builtin.copy module
  # 
  # NOW WITH CHECK MODE SUPPORT!
  # 
  # Supports key Ansible copy module parameters:
  # - src: Source file path on controller (or remote if remote_src=true)
  # - dest: Destination path on remote host
  # - content: Inline content to write to dest (alternative to src)
  # - owner: File owner
  # - group: File group
  # - mode: File permissions (octal or symbolic)
  # - backup: Create backup before overwriting
  # - force: Replace dest if different (default: true)
  # - remote_src: Source file is on remote host
  # - validate: Command to validate file before copying
  # - directory_mode: Permissions for created directories
  # - follow: Follow symlinks
  # - check_mode: If true, don't make changes (dry-run)
  class CopyPlugin < BasePlugin
    property check_mode : Bool
    property diff_mode : Bool
    
    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
      @diff_mode = is_true?(@params["diff_mode"]?)
    end
    
    def execute : PluginResult
      # Get destination (required)
      dest = @params["dest"]?
      unless dest
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: dest"
        )
      end
      
      # Check if using content or src
      content = @params["content"]?
      src = @params["src"]?
      
      # Must have either src or content
      if !src && !content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src or content parameter required"
        )
      end
      
      # Can't have both src and content
      if src && content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src and content are mutually exclusive"
        )
      end
      
      # Handle content-based copy
      if content
        return handle_content_copy(content, dest)
      end
      
      # Handle src-based copy
      if src
        return handle_file_copy(src, dest)
      end
      
      # Should never reach here
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Unexpected error in copy module"
      )
    end
    
    # Copy inline content to destination
    private def handle_content_copy(content : String, dest : String) : PluginResult
      # Calculate MD5 of content for idempotency check
      content_md5 = Digest::MD5.hexdigest(content)
      
      # Get existing content for diff
      existing_content = ""
      if remote_file_exists?(dest)
        cat_result = remote_exec("cat #{dest}")
        existing_content = cat_result[:stdout] if cat_result[:exit_code] == 0
      end
      
      # Check if dest exists and compare
      changed : Bool = true
      if remote_file_exists?(dest)
        # Get MD5 of existing file
        md5_result = remote_exec("md5sum #{dest} 2>/dev/null | awk '{print $1}'")
        if md5_result[:exit_code] == 0
          existing_md5 = md5_result[:stdout].strip
          if existing_md5 == content_md5
            # Content is identical
            force = is_true?(@params["force"]?, default: true)
            unless force
              return PluginResult.new(
                changed: false,
                failed: false,
                msg: "File already exists with same content"
              )
            end
            changed = false
          end
        end
      end
      
      # Generate diff if in diff mode and content changed
      diff_data = nil
      if @diff_mode && changed
        diff_data = generate_unified_diff(
          existing_content,
          content,
          dest,
          "content"
        )
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would write content to #{dest} (check mode)",
            diff: diff_data
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already has correct content (check mode)"
          )
        end
      end
      
      # Create temporary file with content on remote
      temp_file = "/tmp/.crystal-play-copy-#{Random::Secure.hex(8)}.tmp"
      
      # Write content to temp file
      write_cmd = "cat > #{temp_file} << 'CRYSTAL_PLAY_EOF'\n#{content}\nCRYSTAL_PLAY_EOF"
      result = remote_exec(write_cmd)
      
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write content to temporary file",
          stderr: result[:stderr]
        )
      end
      
      # Handle backup if requested
      if changed && is_true?(@params["backup"]?) && remote_file_exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      # Ensure destination directory exists
      dest_dir = File.dirname(dest)
      unless remote_dir_exists?(dest_dir)
        dir_mode = @params["directory_mode"]? || "0755"
        result = remote_exec("mkdir -p #{dest_dir}")
        if result[:exit_code] != 0
          remote_exec("rm -f #{temp_file}")
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to create destination directory: #{dest_dir}"
          )
        end
        remote_exec("chmod #{dir_mode} #{dest_dir}")
      end
      
      # Validate if requested
      if validate_cmd = @params["validate"]?
        if !validate_file(temp_file, validate_cmd)
          remote_exec("rm -f #{temp_file}")
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Validation failed"
          )
        end
      end
      
      # Move temp file to destination
      result = remote_exec("mv -f #{temp_file} #{dest}")
      if result[:exit_code] != 0
        remote_exec("rm -f #{temp_file}")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to move file to destination",
          stderr: result[:stderr]
        )
      end
      
      # Set ownership and permissions
      apply_file_attributes(dest)
      
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Content written to file" : "File updated",
        diff: diff_data,
        dest: dest
      )
    end
    
    # Copy file from src to dest
    private def handle_file_copy(src : String, dest : String) : PluginResult
      remote_src = is_true?(@params["remote_src"]?)
      
      if remote_src
        # Copy from remote location to remote location
        return handle_remote_to_remote_copy(src, dest)
      else
        # Copy from controller to remote
        return handle_controller_to_remote_copy(src, dest)
      end
    end
    
    # Copy from controller (local) to remote host
    private def handle_controller_to_remote_copy(src : String, dest : String) : PluginResult
      # Check if source exists locally
      unless File.exists?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Source file not found: #{src}"
        )
      end
      
      # Handle directory copy with rsync
      if File.directory?(src)
        return handle_directory_copy_rsync(src, dest)
      end
      
      # Calculate source file MD5
      src_md5 = Digest::MD5.hexdigest(File.read(src))
      
      # Check if dest exists and compare
      changed : Bool = true
      force = is_true?(@params["force"]?, default: true)
      
      if remote_file_exists?(dest)
        unless force
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already exists (use force=yes to overwrite)"
          )
        end
        
        # Compare checksums for idempotency
        md5_result = remote_exec("md5sum #{dest} 2>/dev/null | awk '{print $1}'")
        if md5_result[:exit_code] == 0
          dest_md5 = md5_result[:stdout].strip
          if dest_md5 == src_md5
            changed = false
          end
        end
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would copy #{src} to #{dest} (check mode)"
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already identical (check mode)"
          )
        end
      end
      
      # If file is identical, just update attributes if requested
      unless changed
        apply_file_attributes(dest)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest
        )
      end
      
      # Create backup if requested and file will change
      if is_true?(@params["backup"]?) && remote_file_exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      # Ensure destination directory exists
      dest_dir = File.dirname(dest)
      unless remote_dir_exists?(dest_dir)
        dir_mode = @params["directory_mode"]? || "0755"
        result = remote_exec("mkdir -p #{dest_dir}")
        if result[:exit_code] != 0
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to create destination directory: #{dest_dir}"
          )
        end
        remote_exec("chmod #{dir_mode} #{dest_dir}")
      end
      
      # Upload file to temporary location first
      temp_dest = "/tmp/.crystal-play-copy-#{Random::Secure.hex(8)}.tmp"
      
      begin
        remote_upload(src, temp_dest)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to upload file: #{ex.message}"
        )
      end
      
      # Validate if requested
      if validate_cmd = @params["validate"]?
        if !validate_file(temp_dest, validate_cmd)
          remote_exec("rm -f #{temp_dest}")
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Validation failed"
          )
        end
      end
      
      # Move to final destination
      result = remote_exec("mv -f #{temp_dest} #{dest}")
      if result[:exit_code] != 0
        remote_exec("rm -f #{temp_dest}")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to move file to destination"
        )
      end
      
      # Set ownership and permissions
      apply_file_attributes(dest)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "File copied successfully",
        dest: dest,
        checksum: src_md5
      )
    end
    
    # Copy from remote location to remote location
    private def handle_remote_to_remote_copy(src : String, dest : String) : PluginResult
      # Check if source exists on remote
      unless remote_file_exists?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Source file not found on remote: #{src}"
        )
      end
      
      # Check if it's a directory
      dir_check = remote_exec("test -d #{src}")
      is_directory = dir_check[:exit_code] == 0
      
      # Compare files for idempotency
      changed : Bool = true
      if !is_directory && remote_file_exists?(dest)
        cmp_result = remote_exec("cmp -s #{src} #{dest}")
        if cmp_result[:exit_code] == 0
          changed = false
        end
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would copy #{src} to #{dest} on remote (check mode)"
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Files are identical (check mode)"
          )
        end
      end
      
      if changed && is_true?(@params["backup"]?) && remote_file_exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      if is_directory
        # Use cp -r for directories
        result = remote_exec("cp -r #{src} #{dest}")
        if result[:exit_code] != 0
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to copy directory",
            stderr: result[:stderr]
          )
        end
      else
        if changed
          # Use cp to copy file
          result = remote_exec("cp -f #{src} #{dest}")
          if result[:exit_code] != 0
            return PluginResult.new(
              changed: false,
              failed: true,
              msg: "Failed to copy file",
              stderr: result[:stderr]
            )
          end
        end
      end
      
      # Set ownership and permissions
      apply_file_attributes(dest)
      
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "File copied successfully" : "Files are identical",
        dest: dest
      )
    end
    
    # Handle directory copy using rsync
    private def handle_directory_copy_rsync(src : String, dest : String) : PluginResult
      # Check if rsync is available on remote
      rsync_check = remote_exec("which rsync")
      has_rsync = rsync_check[:exit_code] == 0
      
      unless has_rsync
        # Fall back to tar method if rsync not available
        return handle_directory_copy_tar(src, dest)
      end
      
      # Build rsync options
      rsync_opts = ["-a"]  # Archive mode (recursive, preserve permissions, times, etc.)
      
      # Add verbose if needed
      # rsync_opts << "-v" if @verbose
      
      # Handle trailing slash (Ansible-compatible behavior)
      # src/ copies contents, src copies directory itself
      src_path = src.ends_with?("/") ? src : "#{src}/"
      
      # CHECK MODE: Use rsync --dry-run
      if @check_mode
        rsync_opts << "--dry-run"
        rsync_opts << "--itemize-changes"
      end
      
      # Create temp marker file for rsync transfer
      temp_marker = "/tmp/.crystal-play-rsync-#{Random::Secure.hex(8)}"
      
      # Use rsync over SSH
      # Note: This requires rsync on both local and remote
      rsync_cmd = "rsync #{rsync_opts.join(" ")} -e 'ssh -p #{@host.port}' #{src_path} #{@host.user || "root"}@#{@host.name}:#{dest}"
      
      # Execute rsync locally
      rsync_result = `#{rsync_cmd} 2>&1`
      rsync_exit = $?.exit_code
      
      if rsync_exit != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "rsync failed",
          stderr: rsync_result
        )
      end
      
      # In check mode, parse rsync output to determine if changes would be made
      if @check_mode
        # rsync --dry-run output shows what would change
        changed = !rsync_result.strip.empty?
        
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: changed ? "Would copy directory with rsync (check mode)" : "Directory already synchronized (check mode)"
        )
      end
      
      # Set ownership and permissions recursively
      apply_file_attributes(dest, recursive: true)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Directory copied successfully with rsync",
        dest: dest
      )
    end
    
    # Fallback: Handle directory copy using tar (when rsync unavailable)
    private def handle_directory_copy_tar(src : String, dest : String) : PluginResult
      # CHECK MODE: Don't actually copy
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would copy directory with tar (check mode, rsync not available)"
        )
      end
      
      # Create temp directory on remote
      temp_dir = "/tmp/.crystal-play-dir-#{Random::Secure.hex(8)}"
      result = remote_exec("mkdir -p #{temp_dir}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create temporary directory"
        )
      end
      
      # Create tar locally
      tar_file = "/tmp/.crystal-play-tar-#{Random::Secure.hex(8)}.tar"
      system("tar -cf #{tar_file} -C #{File.dirname(src)} #{File.basename(src)}")
      
      # Upload tar
      begin
        remote_upload(tar_file, tar_file)
      rescue ex
        File.delete(tar_file) if File.exists?(tar_file)
        remote_exec("rm -rf #{temp_dir}")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to upload directory: #{ex.message}"
        )
      end
      
      # Clean up local tar
      File.delete(tar_file) if File.exists?(tar_file)
      
      # Extract on remote
      result = remote_exec("tar -xf #{tar_file} -C #{temp_dir}")
      remote_exec("rm -f #{tar_file}")
      
      if result[:exit_code] != 0
        remote_exec("rm -rf #{temp_dir}")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to extract directory on remote"
        )
      end
      
      # Move to destination
      src_basename = File.basename(src)
      result = remote_exec("mv #{temp_dir}/#{src_basename} #{dest}")
      remote_exec("rm -rf #{temp_dir}")
      
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to move directory to destination"
        )
      end
      
      # Set ownership and permissions recursively
      apply_file_attributes(dest, recursive: true)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Directory copied successfully (tar method)",
        dest: dest
      )
    end
    
    # Create backup of file
    private def create_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Random.rand(10000..99999)}.#{timestamp}~"
      remote_exec("cp -p #{path} #{backup_path}")
      backup_path
    end
    
    # Validate file with command
    private def validate_file(path : String, validate_cmd : String) : Bool
      # Replace %s with file path
      cmd = validate_cmd.gsub("%s", path)
      result = remote_exec(cmd)
      result[:exit_code] == 0
    end
    
    # Apply file attributes (owner, group, mode)
    private def apply_file_attributes(path : String, recursive : Bool = false)
      # Set owner
      if owner = @params["owner"]?
        cmd = recursive ? "chown -R #{owner} #{path}" : "chown #{owner} #{path}"
        remote_exec(cmd)
      end
      
      # Set group
      if group = @params["group"]?
        cmd = recursive ? "chgrp -R #{group} #{path}" : "chgrp #{group} #{path}"
        remote_exec(cmd)
      end
      
      # Set mode
      if mode = @params["mode"]?
        # Handle both octal (0644) and symbolic (u=rw,g=r,o=r) modes
        cmd = recursive ? "chmod -R #{mode} #{path}" : "chmod #{mode} #{path}"
        remote_exec(cmd)
      end
    end
    
    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::CopyPlugin.new(config)
plugin.run
