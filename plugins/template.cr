#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Template plugin - writes pre-rendered template content to files
  # 
  # This plugin ONLY works with action plugins.
  # The template_action_plugin reads and renders the template on the controller,
  # then sends the rendered content to this plugin to write to the remote.
  # 
  # Parameters:
  #   content (required): Pre-rendered template content from action plugin
  #   dest (required): Destination path on remote host
  #   owner (optional): File owner
  #   group (optional): File group
  #   mode (optional): File permissions (octal or symbolic)
  #   backup (optional): Create backup before overwriting
  #   validate (optional): Command to validate file before moving to dest
  #   check_mode (optional): Dry-run mode
  #
  # This is a simplified version that delegates all rendering to the action plugin.
  class TemplatePlugin < BasePlugin
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
      
      # Get content (required - should come from action plugin)
      content = @params["content"]?
      unless content
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: content. This plugin requires the template_action_plugin to render the template on the controller first."
        )
      end
      
      # Calculate MD5 of content
      content_md5 = Digest::MD5.hexdigest(content)
      
      # Get existing content for diff
      existing_content = ""
      if File.exists?(dest)
        begin
          existing_content = File.read(dest)
        rescue ex
          # File exists but can't read - continue anyway
        end
      end
      
      # Check if content is identical (idempotency)
      changed = true
      if File.exists?(dest)
        existing_md5 = Digest::MD5.hexdigest(existing_content)
        if existing_md5 == content_md5
          # Content is identical - no change needed!
          changed = false
        end
      end
      
      # Generate diff if in diff mode and content changed
      diff_data = nil
      if @diff_mode && changed
        src_name = @params["_rendered_from_template"]? || "template"
        diff_data = generate_unified_diff(
          existing_content,
          content,
          dest,
          src_name
        )
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would write rendered template to #{dest} (check mode)",
            diff: diff_data
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Template already rendered correctly (check mode)",
            diff: diff_data
          )
        end
      end
      
      # If content is identical, just update attributes if requested
      unless changed
        apply_file_attributes(dest)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: content_md5
        )
      end
      
      # Content will change - create backup if requested
      backup_file = ""
      if is_true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
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
      
      # Write to temporary file first (for atomic write + validation).
      # Staged in *dest_dir* itself, not a global /tmp path: `File.rename`
      # is only atomic (and only works at all) within a single
      # filesystem - `/tmp` is very commonly its own separate tmpfs mount
      # (systemd's tmp.mount, on by default on many modern distros even
      # before any hardening role touches it), so renaming a /tmp staging
      # file onto a destination elsewhere on disk hit "Invalid
      # cross-device link" and failed the whole task. Found via
      # konstruktoid-hardening's "Configure sshd using sshd_config.d" task
      # (writing to /usr/lib/tmpfiles.d/ssh.conf).
      temp_file = File.join(dest_dir, ".crystal-play-template-#{Random::Secure.hex(8)}.tmp")
      
      begin
        # Write content using native Crystal File.write
        File.write(temp_file, content)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write temporary file: #{ex.message}"
        )
      end
      
      # Validate if requested
      if validate_cmd = @params["validate"]?
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          File.delete(temp_file) if File.exists?(temp_file)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Validation failed: #{validation[:output]}"
          )
        end
      end
      
      # Move temp file to destination (atomic operation)
      begin
        File.rename(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to move file to destination: #{ex.message}"
        )
      end
      
      # Set ownership and permissions
      apply_file_attributes(dest)
      
      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Template rendered successfully",
        diff: diff_data,
        dest: dest,
        checksum: content_md5,
        backup_file: backup_file.empty? ? nil : backup_file
      )
    end
    
    # Create backup of existing file
    private def create_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Random.rand(10000..99999)}.#{timestamp}~"
      
      begin
        File.copy(path, backup_path)
        backup_path
      rescue
        # Backup failed, continue anyway
        ""
      end
    end
    
    # Validate file with command. Captures stdout+stderr (not discarded,
    # as this used to) so a validation failure - real Ansible's own
    # `validate:` commands are typically `sshd -T -f %s`/`nginx -t -c
    # %s`-style syntax checkers whose whole purpose is to explain exactly
    # what's wrong - reports *what* failed, not just that it did.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, output: String)
      cmd = validate_cmd.gsub("%s", path)
      output = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: output,
        error: output
      )

      {ok: result.exit_code == 0, output: output.to_s.strip}
    end
    
    # Apply file attributes (owner, group, mode)
    private def apply_file_attributes(path : String)
      # Set mode (permissions) using native Crystal
      if mode = @params["mode"]?
        begin
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
      
      # Owner and group would require chown/chgrp system calls
      # For now, use shell commands for these (they need root anyway)
      if owner = @params["owner"]?
        Process.run("chown", [owner, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
      
      if group = @params["group"]?
        Process.run("chgrp", [group, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
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

plugin = CrystalPlay::TemplatePlugin.new(config)
plugin.run
