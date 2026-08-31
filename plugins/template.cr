#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "../src/krikri/base_plugin"

module Krikri
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
    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
      @diff_mode = true?(@params["diff_mode"]?)
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
      dest = expand_tilde(dest)

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
      if true?(@params["backup"]?) && File.exists?(dest)
        backup_file = create_backup(dest)
      end

      # Real Ansible's template/copy modules do NOT create a missing
      # destination directory - they fail with this exact message
      # ("Destination directory X does not exist"). This plugin used to
      # silently `Dir.mkdir_p` it instead, diverging from real Ansible
      # only when the parent genuinely didn't exist yet (the common case
      # - dest already inside an existing dir like /etc/nginx - never hit
      # this path). Found benchmarking bertvv.mariadb's own "Add official
      # MariaDB repository (yum)" task templating into /etc/yum.repos.d
      # on Ubuntu, where that directory never exists: real Ansible
      # refused the task; krikri quietly created the directory and wrote
      # the file, reporting `changed` where real Ansible reported
      # `failed`.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Destination directory #{dest_dir} does not exist"
        )
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
      temp_file = File.join(dest_dir, ".krikri-playbook-template-#{Random::Secure.hex(8)}.tmp")

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
          # Left in place (not deleted) deliberately - a validation
          # failure means the rendered content itself is almost always
          # what's actually wrong, and there's no other way to inspect
          # what got rendered (the real destination file was never
          # touched). The path is in the message specifically so it's
          # not just silently orphaned.
          #
          # Also inlines a few lines of context around whatever line
          # number the validator's own output cites (`sshd -T`/`nginx
          # -t`-style tools report "line N: ..."), read directly from
          # this plugin's own filesystem (it's already running ON the
          # target host) - a second SSH round trip to fetch the file
          # separately isn't guaranteed to still be possible by the time
          # anyone looks (the whole play keeps running past this one
          # failed task, and can reach a task that drops the control
          # connection - e.g. this exact template's own role locking out
          # SSH access later in the same play - well before a human gets
          # a chance to inspect it).
          context = extract_error_context(temp_file, validation[:output])
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Validation failed: #{validation[:output]} (rendered content left at #{temp_file} for inspection)#{context}"
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

    # Reads a few lines of context out of *path* around whatever line
    # number *validator_output* cites (`"...: line 34: ..."`, the shape
    # `sshd -T`/most other line-oriented config validators use). Returns
    # "" (not an error) if the output doesn't cite a line number, or the
    # file can't be read - this is best-effort diagnostic content, never
    # something a caller should treat as required.
    private def extract_error_context(path : String, validator_output : String) : String
      # `sshd -T`'s own line-citing format varies by which check failed -
      # sometimes "path: line N: message", sometimes "path line N:
      # message" (no colon before "line") - matched loosely enough to
      # catch both rather than assuming one specific validator's exact
      # phrasing.
      return "" unless match = validator_output.match(/line\s+(\d+):/)
      line_num = match[1].to_i

      lines = File.read_lines(path)
      from = Math.max(0, line_num - 3)
      to = Math.min(lines.size - 1, line_num + 1)
      return "" if from > to

      context_lines = (from..to).map { |i| "#{i + 1}: #{lines[i]}" }.join("\n")
      "\n--- context around line #{line_num} ---\n#{context_lines}"
    rescue
      ""
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
          # Real Ansible parses ANY all-digit mode string as octal,
          # leading zero or not (`mode: "640"` and `mode: "0640"` are
          # identical - only a *symbolic* mode like `u+x` isn't valid
          # octal digits). Real bug found benchmarking robertdebock.redis
          # (round 40): `mode: "{{ redis_mode }}"` rendered to the plain
          # string "640" (no leading zero, from a Jinja dict-lookup
          # default, not a literal YAML octal) - the old `starts_with?
          # ("0") ? octal : decimal` branch treated it as DECIMAL 640,
          # producing octal 1200 (`--w------T`) instead of 0640
          # (`rw-r-----`), leaving redis-server unable to even read its
          # own config file. Matches file.cr's own `parse_numeric_mode`.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          end
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
    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::TemplatePlugin.new(config)
plugin.run
