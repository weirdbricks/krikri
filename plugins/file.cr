#!/usr/bin/env crystal

require "json"
require "file_utils"
require "system/user"
require "system/group"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/stat_fields"

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
  #
  # Entirely native: existence/type checks (`Dir.exists?`/`File.exists?`/
  # `File.file?`), directory creation (`Dir.mkdir_p`), removal
  # (`File.delete?`/`FileUtils.rm_rf`), symlink/hardlink creation
  # (`File.symlink`/`File.link`/`File.readlink`), timestamps
  # (`File.utime`), and numeric-mode chown/chmod (`File.chown`/
  # `File.chmod`) replace what used to be 27 separate `remote_exec`
  # calls - `mkdir -p`/`test -f`/`test -e`/`readlink`/`rm -f`/`rm -rf`/
  # `ln -s`/`ln`/`touch` (all four variants)/`stat -c '%U'`/`'%G'`/`'%a'`/
  # `chown`/`chgrp`/`chmod`. Current owner/group/mode are read via a raw
  # `LibC.lstat` (matching what `stat -c` without `-L` does: it does NOT
  # follow symlinks, unlike `test -e`/`test -f`/`File.exists?` which do -
  # this file replicates that same split rather than "fixing" it, since
  # the goal is a mechanical shell->native conversion, not a behavior
  # change).
  #
  # One genuine, narrow gap remains: *symbolic* mode strings (`u+x`,
  # `go-w`, etc.) still shell to the real `chmod` binary to apply, since
  # correctly reimplementing chmod(1)'s symbolic-mode grammar (scopes,
  # `+`/`-`/`=`, `X`, comma-clauses) natively is real, separate scope -
  # numeric mode (the overwhelming majority of real playbooks) is fully
  # native. This matches the *existing* (pre-conversion) limitation
  # documented in `normalize_mode` below, not a new one introduced here.
  class FilePlugin < BasePlugin
    property check_mode : Bool
    property diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
      @diff_mode = is_true?(@params["diff_mode"]?)
    end

    def execute : PluginResult
      # Get path (required). Real Ansible's file module accepts `path`,
      # `dest`, and `name` interchangeably; dest is what many roles write
      # (dev-sec os_hardening's rhosts/netrc cleanup uses `dest:`).
      path = @params["path"]? || @params["dest"]? || @params["name"]?
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
      exists = Dir.exists?(path)

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
      created = begin
        Dir.mkdir_p(path)
        true
      rescue
        false
      end
      unless created
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create directory"
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
      # Check if path exists at all (follows symlinks, matching the
      # original `test -f`'s own dangling-symlink-is-"missing" behavior)
      unless File.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "File does not exist: #{path}. Use state=touch to create it."
        )
      end

      # Check if it's actually a regular file (not directory or link). A
      # directory at a path where the task did not set state: directory is
      # still valid - real Ansible's file module updates a directory's
      # attributes under its default state: file (dev-sec os_hardening
      # loops a mode:/owner:/group: task over a list that mixes /etc/crontab
      # and /etc/cron.* directories), so treat that as a directory
      # attribute update rather than an error. A symlink, on the other
      # hand, is genuinely not something the default file state manages.
      if Dir.exists?(path)
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

      unless File.file?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path exists but is neither a regular file nor a directory: #{path}"
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
      current_target = try_readlink(path)
      if current_target
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

      # Check if something exists at path (follows symlinks, matching
      # `test -e`'s own dangling-symlink-is-"missing" behavior)
      if File.exists?(path)
        force = is_true?(@params["force"]?)
        unless force
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Path exists and is not the correct link. Use force=yes to overwrite."
          )
        end

        # Remove existing file/link
        File.delete?(path)
      end

      # Create symbolic link
      created = begin
        File.symlink(src, path)
        true
      rescue ex
        @last_error = ex.message
        false
      end
      unless created
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create symbolic link",
          stderr: @last_error || ""
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

      # Check if hard link already exists (same inode)
      src_stat = lstat(src)
      dest_stat = lstat(path)
      if src_stat && dest_stat && src_stat.st_ino == dest_stat.st_ino
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

      # Hard link doesn't exist
      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          msg: "Would create hard link (check mode)"
        )
      end

      # Check if dest exists
      if File.exists?(path)
        force = is_true?(@params["force"]?)
        unless force
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Path exists. Use force=yes to overwrite."
          )
        end
        File.delete?(path)
      end

      # Create hard link
      created = begin
        File.link(src, path)
        true
      rescue ex
        @last_error = ex.message
        false
      end
      unless created
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create hard link",
          stderr: @last_error || ""
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
      exists = File.exists?(path)

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
        touched = touch_now(path)
        unless touched
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to touch file"
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
      created = begin
        File.open(path, "w") { }
        true
      rescue
        false
      end
      unless created
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to create file"
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
      unless File.exists?(path)
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

      # Remove files, directories, and links (like rm -rf)
      removed = begin
        FileUtils.rm_rf(path)
        true
      rescue ex
        @last_error = ex.message
        false
      end
      unless removed
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to remove path",
          stderr: @last_error || ""
        )
      end

      PluginResult.new(
        changed: true,
        failed: false,
        msg: "Path removed",
        path: path
      )
    end

    # Check if attributes need updating. Uses a raw `lstat` (not
    # `File::Info`, whose `permissions.value` strips the setuid/setgid/
    # sticky bits) so a requested numeric mode's special bits compare
    # correctly - matches what `stat -c '%U'`/`'%G'`/`'%a'` (no `-L`,
    # i.e. not following symlinks) did before.
    private def update_attributes_if_needed(path : String, is_directory : Bool) : Bool
      changed = false
      info = lstat(path)
      return false unless info

      # Check owner
      if owner = @params["owner"]?
        current_owner = owner_name(info.st_uid)
        changed = true if current_owner != owner
      end

      # Check group
      if group = @params["group"]?
        current_group = group_name(info.st_gid)
        changed = true if current_group != group
      end

      # Check mode
      if mode = @params["mode"]?
        current_mode = PluginHelpers::StatFields.perm_octal(info.st_mode.to_i32)
        # Normalize mode for comparison
        target_mode = normalize_mode(mode)
        changed = true if current_mode != target_mode
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
      apply_single_file_attributes(path)
      return unless recursive
      walk_apply_attributes(path)
    end

    private def walk_apply_attributes(dir : String)
      Dir.each_child(dir) do |child|
        child_path = File.join(dir, child)
        apply_single_file_attributes(child_path)
        info = File.info?(child_path, follow_symlinks: false)
        walk_apply_attributes(child_path) if info && info.directory? && !info.symlink?
      end
    rescue
      # Permission denied, etc. - skip this directory rather than
      # failing the whole task (matches the previous shell implementation
      # not checking chown -R/chmod -R's exit code either).
    end

    private def apply_single_file_attributes(path : String)
      uid = -1
      gid = -1

      if owner = @params["owner"]?
        if user = System::User.find_by?(name: owner)
          uid = user.id.to_i
        end
      end

      if group = @params["group"]?
        if grp = System::Group.find_by?(name: group)
          gid = grp.id.to_i
        end
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      if mode = @params["mode"]?
        apply_mode(path, mode)
      end
    rescue
      # A chmod/chown failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches the previous shell implementation's
      # behavior of not checking these commands' exit codes either.
    end

    private def apply_mode(path : String, mode : String)
      if numeric = parse_numeric_mode(mode)
        File.chmod(path, numeric)
      else
        # Symbolic mode (e.g. "u+x", "go-w") - see the class doc comment.
        remote_exec("chmod #{mode} #{path}")
      end
    end

    private def parse_numeric_mode(mode : String) : Int32?
      return nil unless mode =~ /\A0?[0-7]{3,4}\z/
      mode.to_i(8)
    end

    # Update access and modification times
    private def update_times(path : String)
      # Handle modification_time
      if mod_time = @params["modification_time"]?
        case mod_time.downcase
        when "now"
          set_time(path, mtime: Time.utc)
        when "preserve"
          # Don't change
        else
          # Specific timestamp (YYYYMMDDhhmm.ss)
          set_time(path, mtime: parse_touch_timestamp(mod_time))
        end
      end

      # Handle access_time
      if acc_time = @params["access_time"]?
        case acc_time.downcase
        when "now"
          set_time(path, atime: Time.utc)
        when "preserve"
          # Don't change
        else
          # Specific timestamp
          set_time(path, atime: parse_touch_timestamp(acc_time))
        end
      end
    end

    private def touch_now(path : String) : Bool
      File.utime(Time.utc, Time.utc, path)
      true
    rescue
      false
    end

    # `File.utime` always takes both atime and mtime, so setting just one
    # (matching `touch -a`/`touch -m`'s own single-timestamp behavior)
    # means reading the other one's current value first. `File::Info`
    # only exposes `modification_time`, not `access_time`, so a raw
    # (following) `stat` is used instead - same as `native_stat`.
    private def set_time(path : String, atime : Time? = nil, mtime : Time? = nil)
      current = stat(path)
      return unless current
      new_atime = atime || Time.unix(current.st_atim.tv_sec.to_i64)
      new_mtime = mtime || Time.unix(current.st_mtim.tv_sec.to_i64)
      File.utime(new_atime, new_mtime, path)
    rescue
    end

    private def stat(path : String) : LibC::Stat?
      s = uninitialized LibC::Stat
      result = LibC.stat(path, pointerof(s))
      result == 0 ? s : nil
    end

    # Parses Ansible's own `modification_time`/`access_time` timestamp
    # format, `YYYYMMDDhhmm.ss` - the same format `touch -t` expects,
    # interpreted in local time (matching `touch -t`, not UTC).
    private def parse_touch_timestamp(value : String) : Time
      match = value.match(/\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(?:\.(\d{2}))?\z/)
      raise ArgumentError.new("invalid timestamp: #{value}") unless match
      year, month, day, hour, minute = match[1].to_i, match[2].to_i, match[3].to_i, match[4].to_i, match[5].to_i
      second = match[6]?.try(&.to_i) || 0
      Time.local(year, month, day, hour, minute, second)
    end

    private def lstat(path : String) : LibC::Stat?
      stat = uninitialized LibC::Stat
      result = LibC.lstat(path, pointerof(stat))
      result == 0 ? stat : nil
    end

    private def try_readlink(path : String) : String?
      File.readlink(path)
    rescue
      nil
    end

    private def owner_name(uid : LibC::UidT) : String
      System::User.find_by?(id: uid.to_s).try(&.username) || uid.to_s
    end

    private def group_name(gid : LibC::GidT) : String
      System::Group.find_by?(id: gid.to_s).try(&.name) || gid.to_s
    end

    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end

    # Generate attribute diff for file
    private def get_attribute_diff(path : String) : JSON::Any?
      return nil unless @diff_mode
      info = lstat(path)
      return nil unless info

      before = {} of String => String
      after = {} of String => String

      # Get current mode
      if @params["mode"]?
        before["mode"] = PluginHelpers::StatFields.perm_octal(info.st_mode.to_i32)
        after["mode"] = @params["mode"].to_s
      end

      # Get current owner
      if @params["owner"]?
        before["owner"] = owner_name(info.st_uid)
        after["owner"] = @params["owner"].to_s
      end

      # Get current group
      if @params["group"]?
        before["group"] = group_name(info.st_gid)
        after["group"] = @params["group"].to_s
      end

      return nil if before.empty?

      generate_attribute_diff(before, after)
    end

    @last_error : String? = nil
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::FilePlugin.new(config)
plugin.run
