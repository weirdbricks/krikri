#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Copy plugin - copies files to destinations
  # This version ALWAYS uses native Crystal file operations
  # The PluginManager handles uploading to remote hosts if needed
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
        result = handle_file_copy(src, dest)

        # __cleanup_after_copy - set by TaskExecutor#stage_large_copy_source
        # when src is a remote scratch path it SCP'd the real source to
        # (rather than embedding a huge file's content as a JSON param -
        # see that method's own comment), not the user's real src: value.
        # Best-effort: a leftover /tmp scratch file is far less harmful
        # than a failed cleanup masking the copy's own real result.
        if @params["__cleanup_after_copy"]? == "true"
          File.delete(src) rescue nil
        end

        return result
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
      
      # Check if file exists and compare
      if File.exists?(dest)
        begin
          existing_content = File.read(dest)
          existing_md5 = Digest::MD5.hexdigest(existing_content)
          
          if existing_md5 == content_md5
            # Content is identical - return early!
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "File already exists with identical content",
              dest: dest,
              checksum: content_md5
            )
          end
        rescue ex
          # File read failed, continue with copy
        end
      end
      
      # If we get here, file needs to be written
      changed = true
      
      # Generate diff if in diff mode
      diff_data = nil
      if @diff_mode
        diff_data = generate_unified_diff(
          existing_content,
          content,
          dest,
          "content"
        )
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would write content to #{dest} (check mode)",
          diff: diff_data
        )
      end
      
      # Handle backup if requested
      if is_true?(@params["backup"]?) && File.exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      # Ensure destination directory exists
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        begin
          Dir.mkdir_p(dest_dir)
          
          # Set directory mode if specified
          if dir_mode = @params["directory_mode"]?
            File.chmod(dest_dir, dir_mode.to_i(8))
          end
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to create destination directory: #{ex.message}"
          )
        end
      end
      
      # Write the file using native Crystal
      begin
        File.write(dest, content)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write file: #{ex.message}"
        )
      end
      
      # Set file permissions if requested
      apply_file_attributes(dest)
      
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "Content written to file",
        diff: diff_data,
        dest: dest,
        checksum: content_md5
      )
    end
    
    # Copy file from src to dest
    private def handle_file_copy(src : String, dest : String) : PluginResult
      # Real ansible.builtin.copy: "If dest is a directory, either the
      # file or content will be copied there" - dest is the directory
      # itself, not the final file path, whenever it's already an
      # existing directory (no trailing "/" required). Real bug found
      # benchmarking ansible-community.ansible-vault's own "Install
      # Vault" task (`dest: "{{ vault_bin_path }}"`, defaulting to the
      # plain directory "/usr/local/bin") - previously dest was always
      # treated as a literal file path, so writing to it opened the
      # directory itself with mode "wb" and failed.
      # __original_src_basename - set by TaskExecutor#stage_large_copy_source
      # when src is a random-named remote scratch path it SCP'd the real
      # (large) source file to, not the user's real src: value - using
      # File.basename(src) directly here would append that random
      # scratch filename instead of the real one.
      basename = @params["__original_src_basename"]?.presence || File.basename(src)
      dest = File.join(dest, basename) if Dir.exists?(dest)

      # Check if source exists
      unless File.exists?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Source file not found: #{src}"
        )
      end
      
      # Handle directory copy (not fully implemented yet)
      if File.directory?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Directory copy not yet implemented"
        )
      end
      
      # Calculate source file MD5
      begin
        src_content = File.read(src)
        src_md5 = Digest::MD5.hexdigest(src_content)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read source file: #{ex.message}"
        )
      end
      
      # Check if dest exists and compare
      changed = true
      force = is_true?(@params["force"]?, default: true)
      
      if File.exists?(dest)
        unless force
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already exists (use force=yes to overwrite)"
          )
        end
        
        # Compare checksums for idempotency
        begin
          dest_content = File.read(dest)
          dest_md5 = Digest::MD5.hexdigest(dest_content)
          
          if dest_md5 == src_md5
            # Files are identical
            changed = false
          end
        rescue
          # Ignore, continue with copy
        end
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: changed ? "Would copy #{src} to #{dest} (check mode)" : "File already identical (check mode)"
        )
      end
      
      # If file is identical, just update attributes if requested
      unless changed
        apply_file_attributes(dest)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: src_md5
        )
      end
      
      # Create backup if requested
      if is_true?(@params["backup"]?) && File.exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      # Ensure destination directory exists
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        begin
          Dir.mkdir_p(dest_dir)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to create destination directory: #{ex.message}"
          )
        end
      end
      
      # Copy the file
      begin
        File.copy(src, dest)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to copy file: #{ex.message}"
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
    
    # Create backup of file
    private def create_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Random.rand(10000..99999)}.#{timestamp}~"
      
      begin
        File.copy(path, backup_path)
      rescue
        # Backup failed, continue anyway
      end
      
      backup_path
    end
    
    # Apply file attributes (owner, group, mode)
    private def apply_file_attributes(path : String, recursive : Bool = false)
      # Set mode (permissions)
      if mode = @params["mode"]?
        begin
          # Convert mode string to integer (handles octal like "0644")
          mode_int = if mode.starts_with?("0")
            mode.to_i(8)  # Octal
          else
            mode.to_i     # Decimal
          end
          
          File.chmod(path, mode_int)
        rescue
          # Mode setting failed, continue anyway
        end
      end
      
      # Owner and group would require chown/chgrp which needs root
      # For now, skip these on local operations
      # (They would work via shell when running as root)
      if owner = @params["owner"]?
        # Would need: File.chown(path, owner) - not available in Crystal stdlib
        # Skip for now
      end
      
      if group = @params["group"]?
        # Would need: File.chgrp(path, group) - not available in Crystal stdlib  
        # Skip for now
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
