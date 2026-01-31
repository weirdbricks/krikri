#!/usr/bin/env crystal

require "json"
require "./base_plugin"

module CrystalPlay
  # File plugin - manages files and file properties
  # Compatible with Ansible's ansible.builtin.file module
  # 
  # Supported states:
  # - file: Ensure path exists and is a file
  # - directory: Create directory (like mkdir -p)
  # - link: Create symbolic link
  # - hard: Create hard link
  # - touch: Touch file (create if not exists, update timestamp)
  # - absent: Remove file/directory/link
  #
  # Supported parameters:
  # - path: Path to file/directory (required)
  # - state: Desired state (default: file)
  # - src: Source for links
  # - owner: File owner
  # - group: File group
  # - mode: Permissions (octal or symbolic)
  # - recurse: Recursively apply permissions (directories only)
  # - force: Force symlink creation
  # - follow: Follow symlinks
  # - modification_time: Set modification time (now, preserve, or timestamp)
  # - access_time: Set access time (now, preserve, or timestamp)
  # - check_mode: Dry-run mode
  #
  # Examples:
  #   file:
  #     path: /opt/myapp
  #     state: directory
  #     mode: '0755'
  #
  #   file:
  #     path: /etc/nginx/sites-enabled/default
  #     src: /etc/nginx/sites-available/default
  #     state: link
  class FilePlugin < BasePlugin
    property check_mode : Bool
    property diff_mode : Bool
    
    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
      @diff_mode = is_true?(@params["diff_mode"]?)
    end
    
    def execute : PluginResult
      # Get path (required)
      path = @params["path"]?
      unless path
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: path"
        )
      end
      
      # Get state (default: file)
      state = @params["state"]? || "file"
      
      # Validate state
      valid_states = ["file", "directory", "link", "hard", "touch", "absent"]
      unless valid_states.includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be one of: #{valid_states.join(", ")}"
        )
      end
      
      # Dispatch based on state
      case state
      when "directory"
        handle_directory(path)
      when "file"
        handle_file(path)
      when "link"
        handle_link(path)
      when "hard"
        handle_hard_link(path)
      when "touch"
        handle_touch(path)
      when "absent"
        handle_absent(path)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unhandled state: #{state}"
        )
      end
    end
    
    # Handle state=directory
    private def handle_directory(path : String) : PluginResult
      # Check if directory exists
      exists = remote_dir_exists?(path)
      
      if exists
        # Directory exists, just update attributes if needed
        changed = update_attributes_if_needed(path, is_directory: true)
        
        if @check_mode
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: changed ? "Would update directory attributes (check mode)" : "Directory already correct (check mode)"
          )
        end
        
        if changed
          apply_file_attributes(path, recursive: is_true?(@params["recurse"]?))
        end
        
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: "Directory attributes updated",
          path: path
        )
      end
      
      # Directory doesn't exist, create it
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would create directory (check mode)"
        )
      end
      
      # Create directory (like mkdir -p)
      result = remote_exec("mkdir -p #{path}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create directory",
          stderr: result[:stderr]
        )
      end
      
      # Apply attributes
      apply_file_attributes(path, recursive: is_true?(@params["recurse"]?))
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Directory created",
        path: path
      )
    end
    
    # Handle state=file
    private def handle_file(path : String) : PluginResult
      # Check if file exists
      exists = remote_file_exists?(path)
      
      unless exists
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "File does not exist: #{path}. Use state=touch to create it."
        )
      end
      
      # Check if it's actually a file (not directory or link)
      check_result = remote_exec("test -f #{path}")
      unless check_result[:exit_code] == 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path exists but is not a regular file: #{path}"
        )
      end
      
      # File exists, update attributes if needed
      changed = update_attributes_if_needed(path, is_directory: false)
      
      # Generate diff for attribute changes
      diff_data = changed ? get_attribute_diff(path) : nil
      
      if @check_mode
        return PluginResult.new(
          changed: changed,
          failed: false,
          msg: changed ? "Would update file attributes (check mode)" : "File already correct (check mode)",
          diff: diff_data
        )
      end
      
      if changed
        apply_file_attributes(path)
        update_times(path)
      end
      
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "File attributes updated",
        diff: diff_data,
        path: path
      )
    end
    
    # Handle state=link (symbolic link)
    private def handle_link(path : String) : PluginResult
      src = @params["src"]?
      unless src
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src parameter required for state=link"
        )
      end
      
      # Check if link already exists and points to correct target
      link_check = remote_exec("readlink #{path}")
      if link_check[:exit_code] == 0
        current_target = link_check[:stdout].strip
        if current_target == src
          # Link exists and points to correct target
          changed = update_attributes_if_needed(path, is_directory: false)
          
          if @check_mode
            return PluginResult.new(
              changed: changed,
              failed: false,
              msg: "Link already correct (check mode)"
            )
          end
          
          if changed
            apply_file_attributes(path)
          end
          
          return PluginResult.new(
            changed: changed,
            failed: false,
            msg: "Link already points to #{src}",
            path: path,
            src: src
          )
        end
      end
      
      # Link doesn't exist or points to wrong target
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would create symbolic link (check mode)"
        )
      end
      
      # Check if something exists at path
      exists_check = remote_exec("test -e #{path}")
      if exists_check[:exit_code] == 0
        # Something exists at path
        force = is_true?(@params["force"]?)
        unless force
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Path exists and is not the correct link. Use force=yes to overwrite."
          )
        end
        
        # Remove existing file/link
        remote_exec("rm -f #{path}")
      end
      
      # Create symbolic link
      result = remote_exec("ln -s #{src} #{path}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create symbolic link",
          stderr: result[:stderr]
        )
      end
      
      # Apply attributes (note: for links, this affects the link itself, not target)
      apply_file_attributes(path)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Symbolic link created",
        path: path,
        src: src
      )
    end
    
    # Handle state=hard (hard link)
    private def handle_hard_link(path : String) : PluginResult
      src = @params["src"]?
      unless src
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "src parameter required for state=hard"
        )
      end
      
      # Check if hard link already exists
      # Hard links have the same inode
      inode_check = remote_exec("stat -c '%i' #{src} #{path} 2>/dev/null")
      if inode_check[:exit_code] == 0
        inodes = inode_check[:stdout].split("\n")
        if inodes.size == 2 && inodes[0] == inodes[1]
          # Hard link exists
          if @check_mode
            return PluginResult.new(
              changed: false,
              failed: false,
              msg: "Hard link already exists (check mode)"
            )
          end
          
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Hard link already exists",
            path: path,
            src: src
          )
        end
      end
      
      # Hard link doesn't exist
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would create hard link (check mode)"
        )
      end
      
      # Check if dest exists
      exists_check = remote_exec("test -e #{path}")
      if exists_check[:exit_code] == 0
        force = is_true?(@params["force"]?)
        unless force
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Path exists. Use force=yes to overwrite."
          )
        end
        remote_exec("rm -f #{path}")
      end
      
      # Create hard link
      result = remote_exec("ln #{src} #{path}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create hard link",
          stderr: result[:stderr]
        )
      end
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Hard link created",
        path: path,
        src: src
      )
    end
    
    # Handle state=touch
    private def handle_touch(path : String) : PluginResult
      # Check if file exists
      exists = remote_file_exists?(path)
      
      if exists
        # File exists, update timestamps and attributes
        if @check_mode
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would touch file (check mode)"
          )
        end
        
        # Touch the file
        result = remote_exec("touch #{path}")
        if result[:exit_code] != 0
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to touch file",
            stderr: result[:stderr]
          )
        end
        
        # Update attributes and times
        apply_file_attributes(path)
        update_times(path)
        
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "File touched",
          path: path
        )
      end
      
      # File doesn't exist, create it
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would create file (check mode)"
        )
      end
      
      # Create file
      result = remote_exec("touch #{path}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create file",
          stderr: result[:stderr]
        )
      end
      
      # Apply attributes
      apply_file_attributes(path)
      update_times(path)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "File created",
        path: path
      )
    end
    
    # Handle state=absent
    private def handle_absent(path : String) : PluginResult
      # Check if path exists
      exists_check = remote_exec("test -e #{path}")
      unless exists_check[:exit_code] == 0
        # Path doesn't exist, nothing to do
        if @check_mode
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Path already absent (check mode)"
          )
        end
        
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Path already absent",
          path: path
        )
      end
      
      # Path exists, remove it
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would remove path (check mode)"
        )
      end
      
      # Use rm -rf to remove files, directories, and links
      result = remote_exec("rm -rf #{path}")
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to remove path",
          stderr: result[:stderr]
        )
      end
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Path removed",
        path: path
      )
    end
    
    # Check if attributes need updating
    private def update_attributes_if_needed(path : String, is_directory : Bool) : Bool
      changed = false
      
      # Check owner
      if owner = @params["owner"]?
        stat_result = remote_exec("stat -c '%U' #{path}")
        if stat_result[:exit_code] == 0
          current_owner = stat_result[:stdout].strip
          changed = true if current_owner != owner
        end
      end
      
      # Check group
      if group = @params["group"]?
        stat_result = remote_exec("stat -c '%G' #{path}")
        if stat_result[:exit_code] == 0
          current_group = stat_result[:stdout].strip
          changed = true if current_group != group
        end
      end
      
      # Check mode
      if mode = @params["mode"]?
        stat_result = remote_exec("stat -c '%a' #{path}")
        if stat_result[:exit_code] == 0
          current_mode = stat_result[:stdout].strip
          # Normalize mode for comparison
          target_mode = normalize_mode(mode)
          changed = true if current_mode != target_mode
        end
      end
      
      changed
    end
    
    # Normalize mode to octal string
    private def normalize_mode(mode : String) : String
      # If already octal (e.g., "0755"), strip leading zero
      if mode =~ /^0?\d+$/
        return mode.lstrip('0')
      end
      # For symbolic modes, we'd need more complex parsing
      # For now, return as-is
      mode
    end
    
    # Apply file attributes
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
        cmd = recursive ? "chmod -R #{mode} #{path}" : "chmod #{mode} #{path}"
        remote_exec(cmd)
      end
    end
    
    # Update access and modification times
    private def update_times(path : String)
      # Handle modification_time
      if mod_time = @params["modification_time"]?
        case mod_time.downcase
        when "now"
          # Touch updates mtime to now
          remote_exec("touch #{path}")
        when "preserve"
          # Don't change
        else
          # Specific timestamp (YYYYMMDDhhmm.ss)
          remote_exec("touch -m -t #{mod_time} #{path}")
        end
      end
      
      # Handle access_time
      if acc_time = @params["access_time"]?
        case acc_time.downcase
        when "now"
          remote_exec("touch -a #{path}")
        when "preserve"
          # Don't change
        else
          # Specific timestamp
          remote_exec("touch -a -t #{acc_time} #{path}")
        end
      end
    end
    
    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
    
    # Generate attribute diff for file
    private def get_attribute_diff(path : String) : JSON::Any?
      return nil unless @diff_mode
      
      before = {} of String => String
      after = {} of String => String
      
      # Get current mode
      if @params["mode"]?
        stat_result = remote_exec("stat -c '%a' #{path} 2>/dev/null")
        if stat_result[:exit_code] == 0
          before["mode"] = stat_result[:stdout].strip
          after["mode"] = @params["mode"].to_s
        end
      end
      
      # Get current owner
      if @params["owner"]?
        stat_result = remote_exec("stat -c '%U' #{path} 2>/dev/null")
        if stat_result[:exit_code] == 0
          before["owner"] = stat_result[:stdout].strip
          after["owner"] = @params["owner"].to_s
        end
      end
      
      # Get current group
      if @params["group"]?
        stat_result = remote_exec("stat -c '%G' #{path} 2>/dev/null")
        if stat_result[:exit_code] == 0
          before["group"] = stat_result[:stdout].strip
          after["group"] = @params["group"].to_s
        end
      end
      
      return nil if before.empty?
      
      generate_attribute_diff(before, after)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::FilePlugin.new(config)
plugin.run
