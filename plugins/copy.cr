#!/usr/bin/env crystal

require "json"
require "digest/md5"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
  # Copy plugin - copies files to destinations
  # This version ALWAYS uses native Crystal file operations
  # The PluginManager handles uploading to remote hosts if needed
  class CopyPlugin < BasePlugin
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
        # __original_src_basename - set by TaskExecutor#
        # inline_copy_source_content when a small src: file's content
        # was read on the controller and forwarded as content: instead
        # (see that method's own comment) - the same rewrite copy.cr's
        # own src:-based handle_file_copy already accounts for via this
        # exact param name. Without checking it here too, a `copy:
        # {src: brim.desktop, dest: /usr/share/applications/}` (an
        # existing directory) tried to write straight to the directory
        # itself once inline_copy_source_content rewrote it to content:
        # - "Failed to write file: ... 'Is a directory'" - since only
        # handle_file_copy's OWN dest-is-directory basename-append
        # logic existed, and this path never reaches it.
        if (basename = @params["__original_src_basename"]?.presence) && Dir.exists?(dest)
          dest = File.join(dest, basename)
        end
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

        # __cleanup_after_copy_dir - directory counterpart, set by
        # TaskExecutor#stage_directory_copy_source. src here may carry
        # the trailing "/" that method preserves for the directory-copy
        # dispatch's own convention, which File paths don't need.
        if @params["__cleanup_after_copy_dir"]? == "true"
          FileUtils.rm_rf(src.rstrip('/')) rescue nil
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
        # force: false means "only create it if it is not there" - real
        # Ansible leaves an existing file completely alone, content and
        # all. This branch used to ignore `force` entirely (the `src:`
        # path above has always honoured it), so a `copy:` with
        # `content:` + `force: false` OVERWROTE an existing file rather
        # than skipping it. Found live on mrlesmithjr.mdadm, whose
        # "Ensure mdadm conf file exists" task is exactly
        # `content: "" / force: false` against the distro's own
        # /etc/mdadm/mdadm.conf: real ansible-playbook left the 688-byte
        # file untouched and reported ok, this truncated it to 0 bytes
        # and reported changed. Real data loss, not just a wrong verdict.
        unless true?(@params["force"]?, default: true)
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "File already exists (use force=yes to overwrite)",
            dest: dest
          )
        end

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
      if true?(@params["backup"]?) && File.exists?(dest)
        create_backup(dest)
      end

      # Real Ansible's copy module does NOT create a missing single-file
      # destination directory - it fails with this exact message. See
      # plugins/template.cr's identical fix (same bug, same root cause:
      # a leftover `Dir.mkdir_p` that only diverged from real Ansible
      # once the parent genuinely didn't exist yet) for the repro.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Destination directory #{dest_dir} does not exist"
        )
      end

      # Write the file (staged + validated first when validate: is given)
      if failure = write_with_optional_validate(content, dest)
        return PluginResult.new(changed: false, failed: true, msg: failure)
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
      # __precomputed_match - set by TaskExecutor#precomputed_copy_match
      # when a checksum-first remote check (run BEFORE ever staging src
      # to the remote host at all) already proved the destination holds
      # identical content. `src` here is still the ORIGINAL, controller-
      # only local path in this case (nothing was staged) - checked and
      # returned first, before any of the `src`-dependent logic below
      # ever runs, since evaluating `Dir.exists?(src)`/`File.exists?(src)`
      # against a path that only exists on the controller, from a plugin
      # process actually running on the remote host, would be meaningless
      # at best. Mirrors the "content already identical" branch further
      # down exactly (still applies file attributes - owner/group/mode
      # can differ even when content matches).
      if @params["__precomputed_match"]? == "true"
        basename = @params["__original_src_basename"]?.presence || File.basename(src)
        dest = File.join(dest, basename) if Dir.exists?(dest)
        return PluginResult.new(changed: false, failed: false, msg: "File already identical (check mode)") if @check_mode

        apply_file_attributes(dest)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "File already exists with identical content",
          dest: dest,
          checksum: @params["__precomputed_checksum"]? || ""
        )
      end

      # Directory src - dispatched before any of the file-specific dest
      # resolution below, which doesn't apply to a directory copy (its
      # own trailing-"/" convention decides the dest layout instead).
      return handle_directory_copy(src, dest) if Dir.exists?(src)

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
      force = true?(@params["force"]?, default: true)

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
      if true?(@params["backup"]?) && File.exists?(dest)
        create_backup(dest)
      end

      # Real Ansible's copy module does NOT create a missing single-file
      # destination directory - it fails with this exact message. See
      # #handle_content_copy's identical fix above for the repro.
      dest_dir = File.dirname(dest)
      unless Dir.exists?(dest_dir)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Destination directory #{dest_dir} does not exist"
        )
      end

      # Copy the file (staged + validated first when validate: is given -
      # src_content was already read above for the MD5 check, so this
      # reuses it rather than reading src a second time).
      if @params["validate"]?
        if failure = write_with_optional_validate(src_content, dest)
          return PluginResult.new(changed: false, failed: true, msg: failure)
        end
      else
        begin
          File.copy(src, dest)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to copy file: #{ex.message}"
          )
        end
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

    # Directory src - real Ansible copy: "if src is a directory, it is
    # copied recursively", with a `src:` trailing "/" meaning "copy the
    # CONTENTS of src", no trailing "/" meaning "copy src itself as a
    # subdirectory of dest" (identical to rsync's own convention). Real
    # bug found benchmarking cloudalchemy.prometheus's own "propagate
    # official console templates" task (`src: ".../console_libraries/"`,
    # both trailing-slash) - directory copy was entirely unimplemented,
    # always "Directory copy not yet implemented" (a documented, but
    # real-world-blocking, scope cut).
    #
    # Idempotency is a per-file existence+checksum check (identical to
    # the single-file path's own MD5 comparison), not real Ansible's
    # fuller directory-diff/prune semantics (e.g. `dest:` files with no
    # `src:` counterpart aren't removed) - narrowly scoped to what
    # actually copies a directory tree correctly, matching several other
    # deliberately-scoped gaps already in this codebase.
    private def handle_directory_copy(src : String, dest : String) : PluginResult
      dest_root = src.ends_with?('/') ? dest : File.join(dest, File.basename(src.rstrip('/')))

      begin
        Dir.mkdir_p(dest_root)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to create destination directory: #{ex.message}")
      end

      changed = false
      copied = 0

      Dir.glob(File.join(src, "**", "*"), follow_symlinks: false).sort.each do |entry|
        relative = entry.sub(src.rstrip('/') + "/", "")
        dest_path = File.join(dest_root, relative)

        if File.directory?(entry)
          unless Dir.exists?(dest_path)
            Dir.mkdir_p(dest_path)
            changed = true
          end
          next
        end

        Dir.mkdir_p(File.dirname(dest_path))

        if File.exists?(dest_path) && File.read(dest_path) == File.read(entry)
          apply_file_attributes(dest_path)
          next
        end

        begin
          File.copy(entry, dest_path)
        rescue ex
          return PluginResult.new(changed: changed, failed: true, msg: "Failed to copy #{entry}: #{ex.message}")
        end

        apply_file_attributes(dest_path)
        changed = true
        copied += 1
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Directory copied successfully" : "Directory already up to date",
        dest: dest_root
      )
    end

    # `validate:` support - real Ansible's `copy:` supports it identically
    # to `template:`, which this codebase previously implemented but this
    # plugin never did at all (see KNOWN_MISSING.md's own writeup: found
    # while fixing template.cr's validate:/remote_tmp staging gap).
    # Mirrors template.cr's own approach exactly: stage the final content
    # under /tmp (remote_tmp-style, matching real Ansible's own
    # `~/.ansible/tmp/...` location - see that plugin's own comment on
    # why dest-adjacent staging diverges from real Ansible under
    # AppArmor/SELinux confinement), run the validate: command against
    # the staged file, then move it into place via FileUtils.mv, which
    # already falls back to copy-then-delete on a cross-device
    # (EXDEV/EPERM) move instead of the plain `File.rename` that broke
    # on konstruktoid-hardening. When no validate: is given, writes
    # directly to dest as before - this path is unchanged for the
    # overwhelmingly common no-validate: case.
    #
    # Returns nil on success, or a failure message string.
    private def write_with_optional_validate(content : String, dest : String) : String?
      validate_cmd = @params["validate"]?
      unless validate_cmd
        File.write(dest, content)
        return nil
      end

      temp_file = File.join("/tmp", ".krikri-playbook-copy-#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temp_file, content)
      rescue ex
        return "Failed to write temporary file: #{ex.message}"
      end

      validation = validate_file(temp_file, validate_cmd)
      unless validation[:ok]
        # Left in place deliberately, same reasoning as template.cr's
        # identical choice - the rendered/copied content is almost
        # always what's actually wrong, and this is the only surviving
        # copy of it once the real dest was never touched.
        context = extract_error_context(temp_file, validation[:output])
        return "Validation failed: #{validation[:output]} (content left at #{temp_file} for inspection)#{context}"
      end

      begin
        FileUtils.mv(temp_file, dest)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return "Failed to move file to destination: #{ex.message}"
      end

      nil
    end

    # Validate file with command - identical to template.cr's own
    # helper (captures stdout+stderr so a validation failure explains
    # what's actually wrong, not just that it happened).
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

    # Same context-around-the-cited-line extraction as template.cr's
    # own helper - see that plugin for the full rationale.
    private def extract_error_context(path : String, validator_output : String) : String
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
          # Real Ansible parses ANY all-digit mode string as octal,
          # leading zero or not (`mode: "640"` and `mode: "0640"` are
          # identical). See template.cr's identical fix (round 40,
          # robertdebock.redis) for the full story - the old
          # `starts_with?("0") ? octal : decimal` branch corrupted any
          # templated mode value without a literal leading zero.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          end
        rescue
          # Mode setting failed, continue anyway
        end
      end

      # Real bug found benchmarking cloudalchemy.grafana's own
      # "Create/Update dashboards file (provisioning)" task (copy:
      # content: ..., owner: root, group: grafana) - owner:/group: were
      # never actually applied at all (a genuinely dead stub, not just
      # narrowly scoped - the comments here claimed File.chown/File.chgrp
      # "not available in Crystal stdlib", which is simply wrong; file.cr
      # already uses File.chown successfully elsewhere in this same
      # codebase). The file silently kept its default group (whatever
      # the process creating it was already running as, "root" here
      # rather than the intended "grafana"), which meant Grafana's own
      # service user couldn't read its own dashboard provisioning
      # config, "Failed to create provisioner: ... permission denied" -
      # the whole service refused to start.
      uid = -1
      gid = -1

      if (owner = @params["owner"]?) && (user = System::User.find_by?(name: owner))
        uid = user.id.to_i
      end

      if (group = @params["group"]?) && (grp = System::Group.find_by?(name: group))
        gid = grp.id.to_i
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1
    rescue
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches file.cr's own identical rescue.
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

plugin = Krikri::CopyPlugin.new(config)
plugin.run
