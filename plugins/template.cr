#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "crinja"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Template plugin - renders Jinja2 templates to remote locations
  # Compatible with Ansible's ansible.builtin.template module
  # 
  # Uses Crinja (Crystal Jinja2 implementation) for template rendering
  # 
  # Supported parameters:
  # - src: Template file path on controller (.j2 file)
  # - dest: Destination path on remote host
  # - owner: File owner
  # - group: File group
  # - mode: File permissions (octal or symbolic)
  # - backup: Create backup before overwriting
  # - force: Replace dest if different (default: true)
  # - validate: Command to validate file before copying
  # - trim_blocks: Trim blocks (default: true, matches Ansible)
  # - lstrip_blocks: Strip leading whitespace from block tags
  # - newline_sequence: Line ending (\n, \r, \r\n)
  # - check_mode: If true, don't make changes (dry-run)
  #
  # Template variables come from the 'vars' in the config
  #
  # Examples:
  #   template:
  #     src: /templates/nginx.conf.j2
  #     dest: /etc/nginx/nginx.conf
  #     owner: root
  #     mode: '0644'
  class TemplatePlugin < BasePlugin
    property check_mode : Bool
    property diff_mode : Bool
    
    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
      @diff_mode = is_true?(@params["diff_mode"]?)
    end
    
    def execute : PluginResult
      # Get src and dest (both required)
      src = @params["src"]?
      dest = @params["dest"]?
      
      unless src
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: src"
        )
      end
      
      unless dest
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: dest"
        )
      end
      
      # Check if template file exists locally
      unless File.exists?(src)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Template file not found: #{src}"
        )
      end
      
      # Read template content
      begin
        template_content = File.read(src)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read template file: #{ex.message}"
        )
      end
      
      # Render template
      rendered_content = render_template(template_content, src)
      if rendered_content.nil?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to render template"
        )
      end
      
      # Apply newline sequence if specified
      if newline_seq = @params["newline_sequence"]?
        case newline_seq
        when "\\n"
          rendered_content = rendered_content.gsub(/\r\n|\r/, "\n")
        when "\\r"
          rendered_content = rendered_content.gsub(/\n/, "\r")
        when "\\r\\n"
          rendered_content = rendered_content.gsub(/\r?\n/, "\r\n")
        end
      end
      
      # Calculate MD5 of rendered content
      content_md5 = Digest::MD5.hexdigest(rendered_content)
      
      # Get existing content for diff
      existing_content = ""
      if remote_file_exists?(dest)
        cat_result = remote_exec("cat #{dest}")
        existing_content = cat_result[:stdout] if cat_result[:exit_code] == 0
      end
      
      # Check if dest exists and compare
      changed = true
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
          rendered_content,
          dest,
          "dynamically generated from #{src}"
        )
      end
      
      # CHECK MODE: Report what would change
      if @check_mode
        if changed
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would template #{src} to #{dest} (check mode)",
            diff: diff_data
          )
        else
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Template already rendered correctly (check mode)"
          )
        end
      end
      
      # Create backup if requested and file will change
      if changed && is_true?(@params["backup"]?) && remote_file_exists?(dest)
        backup_dest = create_backup(dest)
      end
      
      # Ensure destination directory exists
      dest_dir = File.dirname(dest)
      unless remote_dir_exists?(dest_dir)
        result = remote_exec("mkdir -p #{dest_dir}")
        if result[:exit_code] != 0
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to create destination directory: #{dest_dir}"
          )
        end
      end
      
      # Create temporary file with rendered content on remote
      temp_file = "/tmp/.crystal-play-template-#{Random::Secure.hex(8)}.tmp"
      
      # Write rendered content to temp file
      write_cmd = "cat > #{temp_file} << 'CRYSTAL_PLAY_EOF'\n#{rendered_content}\nCRYSTAL_PLAY_EOF"
      result = remote_exec(write_cmd)
      
      if result[:exit_code] != 0
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to write rendered template to temporary file",
          stderr: result[:stderr]
        )
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
        msg: changed ? "Template rendered successfully" : "File updated",
        diff: diff_data,
        dest: dest,
        checksum: content_md5
      )
    end
    
    # Render Jinja2 template
    private def render_template(template_content : String, template_path : String) : String?
      begin
        # Create Crinja environment
        env = Crinja.new
        
        # Configure Crinja to match Ansible defaults
        # Ansible uses trim_blocks=True by default since 0.9
        trim_blocks = is_true?(@params["trim_blocks"]?, default: true)
        lstrip_blocks = is_true?(@params["lstrip_blocks"]?, default: false)
        
        env.config.trim_blocks = trim_blocks
        env.config.lstrip_blocks = lstrip_blocks
        
        # Parse custom Jinja2 settings from template header
        # Format: #jinja2:variable_start_string:'[%', variable_end_string:'%]', trim_blocks: False
        if template_content.starts_with?("#jinja2:")
          # Extract first line
          first_line = template_content.lines.first
          # Parse settings (simplified - full parser would be more complex)
          if first_line.includes?("trim_blocks")
            if first_line.includes?("trim_blocks: False") || first_line.includes?("trim_blocks:False")
              env.config.trim_blocks = false
            end
          end
        end
        
        # Prepare template variables
        template_vars = prepare_template_vars
        
        # Add Ansible-specific variables
        # Add Ansible-specific variables
        template_vars["ansible_managed"] = Crinja::Value.new("Ansible managed - DO NOT EDIT")
        template_vars["template_host"] = Crinja::Value.new(@host.name)
        template_vars["template_path"] = Crinja::Value.new(template_path)
        template_vars["template_fullpath"] = Crinja::Value.new(File.expand_path(template_path))
        template_vars["template_run_date"] = Crinja::Value.new(Time.utc.to_s("%Y-%m-%d %H:%M:%S UTC"))
        
        # Render template
        template = env.from_string(template_content)
        rendered = template.render(template_vars)
        
        return rendered
      rescue ex
        STDERR.puts "Template rendering error: #{ex.message}"
        STDERR.puts ex.backtrace.join("\n")
        return nil
      end
    end
    
    # Prepare variables for template rendering
    private def prepare_template_vars : Hash(String, Crinja::Value)
      vars = Hash(String, Crinja::Value).new
      
      # Add all vars from config
      if config_vars = @config["vars"]?
        convert_json_to_crinja(config_vars, vars)
      end
      
      # Add host information (Ansible facts simulation)
      vars["inventory_hostname"] = Crinja::Value.new(@host.name)
      vars["ansible_hostname"] = Crinja::Value.new(@host.name)
      
      # Add common Ansible facts (we'd need to gather these from remote in full implementation)
      # For now, provide basic placeholders
      vars["ansible_user"] = Crinja::Value.new(@host.user || "root")
      vars["ansible_port"] = Crinja::Value.new(@host.port)
      
      vars
    end
    
    # Convert JSON::Any to Crinja::Value recursively
    private def convert_json_to_crinja(json : JSON::Any, target : Hash(String, Crinja::Value))
      case json.raw
      when Hash
        json.as_h.each do |key, value|
          target[key] = json_any_to_crinja_value(value)
        end
      end
    end
    
    # Convert JSON::Any to Crinja::Value
    private def json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
      case json.raw
      when String
        Crinja::Value.new(json.as_s)
      when Int64
        Crinja::Value.new(json.as_i)
      when Float64
        Crinja::Value.new(json.as_f)
      when Bool
        Crinja::Value.new(json.as_bool)
      when Nil
        Crinja::Value.new(nil)
      when Hash
        hash = Hash(String, Crinja::Value).new
        json.as_h.each do |key, value|
          hash[key] = json_any_to_crinja_value(value)
        end
        Crinja::Value.new(hash)
      when Array
        array = json.as_a.map { |item| json_any_to_crinja_value(item) }
        Crinja::Value.new(array)
      else
        Crinja::Value.new(json.to_s)
      end
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
    private def apply_file_attributes(path : String)
      # Set owner
      if owner = @params["owner"]?
        remote_exec("chown #{owner} #{path}")
      end
      
      # Set group
      if group = @params["group"]?
        remote_exec("chgrp #{group} #{path}")
      end
      
      # Set mode
      if mode = @params["mode"]?
        remote_exec("chmod #{mode} #{path}")
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
