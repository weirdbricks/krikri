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
      path = expand_tilde(path)

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

      result = dispatch_state(state, path)

      # Real Ansible's file module always echoes the resolved state:
      # back in its result (dev-sec os_hardening's own molecule test
      # verifies a `register:`'d file: task's `.state` directly:
      # `result_test_netrc.state == 'file'`) - added centrally here
      # rather than in every handle_* branch above, since none of them
      # need to know their own state value to do their actual job.
      result.extra["state"] = JSON::Any.new(state) unless result.failed || result.extra.has_key?("state")
      result
    end

    private def dispatch_state(state : String, path : String) : PluginResult
      case state
      when "directory" then handle_directory(path)
      when "file"      then handle_file(path)
      when "link"      then handle_link(path)
      when "hard"      then handle_hard_link(path)
      when "touch"     then handle_touch(path)
      when "absent"    then handle_absent(path)
      else
        PluginResult.new(changed: false, failed: true, msg: "Unhandled state: #{state}")
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

      # Create directory (like mkdir -p), applying owner/group/mode to
      # each newly-created path COMPONENT along the way, not just the
      # leaf. Real Ansible's own file module (ensure_directory) walks
      # the path component-by-component with a bare os.mkdir per
      # missing dir, explicitly applying attributes to each one it
      # creates; a single Dir.mkdir_p call has no such per-component
      # hook, so a task creating a *nested* path whose intermediate
      # components don't exist yet left every newly-created ancestor
      # directory owned by whoever this process runs as (root) except
      # the leaf, which #apply_file_attributes below still handles.
      #
      # Found benchmarking geerlingguy.solr: "Ensure Solr conf
      # directories exist." (path: .../data/collection1/conf, owner:
      # solr_user, recurse: true) needed a LATER become_user: solr
      # task (`bin/solr create`) to delete/recreate that same conf/
      # subdirectory - which needs WRITE permission on its parent
      # (collection1), and a root-owned 0755 ancestor denies that to a
      # non-root user ("Unable to delete file").
      created = begin
        missing_components = [] of String
        cursor = path
        until cursor.empty? || cursor == "/" || Dir.exists?(cursor)
          missing_components << cursor
          cursor = File.dirname(cursor)
        end
        missing_components.reverse_each do |component|
          Dir.mkdir(component) unless Dir.exists?(component)
          apply_file_attributes(component, recursive: false)
        end
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
      src = expand_tilde(src)

      # Check if link already exists and points to correct target
      current_target = try_readlink(path)
      if current_target
        if current_target == src
          # Link exists and points to correct target
          changed = update_attributes_if_needed(path, is_directory: false, skip_mode: true)

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
      src = expand_tilde(src)

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
        # File exists - real Ansible's own idempotency here: touching
        # only actually changes mtime/atime to "now" when
        # modification_time:/access_time: isn't `preserve` (its default,
        # with no param at all, IS "now" - always changed then), so
        # `modification_time: preserve` + `access_time: preserve` (dev-sec
        # os_hardening's own way of using state=touch as a pure
        # create-if-missing-else-fix-attributes op) must be genuinely
        # idempotent on a second run, not unconditionally bump the
        # timestamps to now and report changed regardless.
        if @check_mode
          return PluginResult.new(
            changed: true,
            failed: false,
            msg: "Would touch file (check mode)"
          )
        end

        attrs_changed = update_attributes_if_needed(path, is_directory: false)
        times_changed = touch_times_would_change?(path)
        changed = attrs_changed || times_changed

        if changed
          apply_file_attributes(path) if attrs_changed
          touch_apply_times(path) if times_changed
        end

        return PluginResult.new(
          changed: changed,
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
    #
    # The follow: parameter (default false, matching real Ansible's
    # file module) flips the read path between lstat and stat
    # (see the stat_follow helper). When true, a `state: file` task
    # with a symlink path compares the TARGET's metadata (owner,
    # group, mode) against the requested values, not the symlink's
    # own. Real bug found benchmarking devsec.hardening.mysql_hardening
    # in round 24 role 2 (the `Protect my.cnf` task has follow: true;
    # previously always used lstat regardless of the follow param, so
    # warm reruns always reported changed because the symlink's
    # permission bits are always 0777 and never match the target's
    # intended 0640 - dev-sec os_hardening's PAM symlinks hit a
    # similar but separate issue handled by the state: link branch
    # below via skip_mode, not this one).
    private def update_attributes_if_needed(path : String, is_directory : Bool, skip_mode : Bool = false) : Bool
      follow = is_true?(@params["follow"]?)
      changed = false
      info = follow ? stat_follow(path) : lstat(path)
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

      # Check mode - skipped for a symlink (handle_link's skip_mode: true).
      # Linux has no real lchmod: a symlink's own permission bits are
      # meaningless (`lrwxrwxrwx` always) and can't actually be changed,
      # so real Ansible's file module doesn't attempt to compare/apply
      # `mode:` against the link itself for `state: link`. Previously
      # compared the target mode against the symlink's always-0777 lstat
      # bits, which never matched, so `state: link` + `mode:` reported
      # changed: true on every single run even when the link already
      # pointed at the right target - dev-sec os_hardening's own PAM
      # `system-auth`/`password-auth` symlinks are set up exactly this
      # way and never converged.
      if mode = @params["mode"]?
        return changed if skip_mode
        if mode =~ /^0?\d+$/
          current_mode = PluginHelpers::StatFields.perm_octal(info.st_mode.to_i32)
          # Normalize mode for comparison - perm_octal returns a 3-digit octal
          # for a 0 special digit ("750") but 4 digits otherwise; the task's
          # mode may be written "0750", "750", "0644", etc. Strip a leading
          # zero from BOTH sides so target "0750" vs current "750" compare
          # equal, while setuid/sticky perms (a 4th digit) still match.
          target_mode = normalize_mode(mode)
          changed = true if current_mode.lstrip('0') != target_mode.lstrip('0')
        else
          # Symbolic mode (`a-s`, `go-w`, ...) - resolve what it would
          # produce against the file's current bits and compare that,
          # instead of always reporting changed the way comparing a raw
          # symbolic string against an octal current_mode always would
          # (dev-sec os_hardening's suid/sgid-blacklist task uses `mode:
          # a-s` on files that are frequently already clean, and a
          # permanently-false "changed" defeats changed_when: logic
          # downstream that keys off it).
          changed = true if resolve_symbolic_mode(info.st_mode.to_i32, mode) != info.st_mode.to_i32
        end
      end

      changed
    end

    # See update_attributes_if_needed above for why this exists. Supports
    # the common u/g/o/a scopes, +/-/= ops, and r/w/x/X/s/t perm chars,
    # comma-separated clauses applied left to right - not every POSIX
    # corner case, but every shape real playbooks (and this project's own
    # fixtures) actually write.
    private def resolve_symbolic_mode(current : Int32, symbolic : String) : Int32
      symbolic.split(',').reduce(current) do |mode, raw_clause|
        clause = raw_clause.strip
        clause.empty? ? mode : apply_symbolic_clause(mode, clause)
      end
    end

    private def apply_symbolic_clause(mode : Int32, clause : String) : Int32
      match = clause.match(/\A([ugoa]*)([+\-=])([rwxXst]*)\z/)
      return mode unless match

      scopes = match[1].empty? ? "ugo" : match[1].gsub("a", "ugo")
      op = match[2][0]
      perms = match[3]
      rwx = symbolic_rwx_bits(mode, perms)

      scopes.each_char do |scope|
        shift = scope == 'u' ? 6 : scope == 'g' ? 3 : 0
        mode = apply_symbolic_bits(mode, 0o7 << shift, rwx << shift, op)
      end

      mode = apply_symbolic_bits(mode, 0o4000, 0o4000, op) if perms.includes?('s') && scopes.includes?('u')
      mode = apply_symbolic_bits(mode, 0o2000, 0o2000, op) if perms.includes?('s') && scopes.includes?('g')
      mode = apply_symbolic_bits(mode, 0o1000, 0o1000, op) if perms.includes?('t')
      mode
    end

    private def symbolic_rwx_bits(mode : Int32, perms : String) : Int32
      rwx = 0
      rwx |= 4 if perms.includes?('r')
      rwx |= 2 if perms.includes?('w')
      executable_somewhere = (mode & 0o111) != 0 || (mode & LibC::S_IFMT) == LibC::S_IFDIR
      rwx |= 1 if perms.includes?('x') || (perms.includes?('X') && executable_somewhere)
      rwx
    end

    private def apply_symbolic_bits(mode : Int32, mask : Int32, bits : Int32, op : Char) : Int32
      case op
      when '+' then mode | bits
      when '-' then mode & ~bits
      else          (mode & ~mask) | bits
      end
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
      follow = is_true?(@params["follow"]?)
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

      # Crystal's File.chown defaults `follow_symlinks: false`, which is
      # lchown(2) - changes the symlink's own owner/group, not the
      # target's. For a task with `follow: true` (the file module's
      # default for state: file), the chown must follow the symlink
      # to change the target. File.chmod is unaffected - the Crystal
      # stdlib's File.chmod always follows (matches the Linux chmod(2)
      # default), so the mode apply was already correct on the target.
      # Real bug found benchmarking devsec.hardening.mysql_hardening
      # in round 24 role 2: the `Protect my.cnf` task (owner: root,
      # group: mysql, follow: true, path: /etc/mysql/my.cnf symlink to
      # .../mariadb.cnf) used lchown, leaving /etc/mysql/mariadb.cnf at
      # root:root with the symlink itself group-changed to mysql -
      # downstream comparisons via the unfixed lstat read path then
      # always reported changed on warm rerun. With follow_symlinks
      # passed through here, the chown now reaches the target.
      File.chown(path, uid: uid, gid: gid, follow_symlinks: follow) if uid != -1 || gid != -1

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

    # Whether touch_apply_times would actually change anything, without
    # applying it - mirrors its own now(default)/preserve/specific-
    # timestamp handling for modification_time:/access_time:. Unlike
    # update_times (used by state=file/link, where no modification_time:/
    # access_time: means "leave timestamps alone entirely"), state=touch's
    # own default with neither given is "now" - matching real Ansible's
    # file module docs ("The default when the mtime and/or atime are not
    # explicitly set is to change these to the current time").
    private def touch_times_would_change?(path : String) : Bool
      current = lstat(path)
      return true unless current

      time_param_would_change?(@params["modification_time"]?, Time.unix(current.st_mtim.tv_sec.to_i64)) ||
        time_param_would_change?(@params["access_time"]?, Time.unix(current.st_atim.tv_sec.to_i64))
    end

    private def time_param_would_change?(param : String?, current_time : Time) : Bool
      case param
      when nil, "now"
        true
      when "preserve"
        false
      else
        parse_touch_timestamp(param) != current_time
      end
    end

    # Applies state=touch's own modification_time:/access_time: semantics
    # (see touch_times_would_change? above for why this differs from
    # update_times) - "preserve" passes nil through to set_time, which
    # reads and rewrites that axis' *current* value rather than skipping
    # it entirely, a true no-op rather than merely "don't pass a new
    # value" (set_time's normal contract for state=file/link callers,
    # where the other axis is genuinely never touched at all).
    private def touch_apply_times(path : String)
      new_mtime = touch_target_time(@params["modification_time"]?)
      new_atime = touch_target_time(@params["access_time"]?)
      set_time(path, atime: new_atime, mtime: new_mtime)
    end

    private def touch_target_time(param : String?) : Time?
      case param
      when nil, "now"
        Time.utc
      when "preserve"
        nil
      else
        parse_touch_timestamp(param)
      end
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

    # Companion to lstat: stat() (not lstat()) - follows symlinks and
    # returns the target's metadata instead of the symlink's own. Used
    # by update_attributes_if_needed when the task has `follow: true`,
    # so a "set owner: group: on /etc/mysql/my.cnf" task reads the
    # target's actual owner/group (root:mysql) for the "is the file
    # already correct?" check, instead of the symlink's owner/group
    # (which is meaningless for ownership purposes - a symlink's
    # owner is whoever its creator was, not who's allowed to traverse
    # it). Real bug found benchmarking devsec.hardening.mysql_hardening
    # in round 24 role 2 (the `Protect my.cnf` task has follow: true
    # and path: /etc/mysql/my.cnf, a symlink to .../mariadb.cnf;
    # lstat returned the symlink's own group=mysql, which was set
    # by a previous run's lchown, while the actual target was still
    # root:root - so warm reruns never converged even after the
    # chown was fixed to follow symlinks, because the read path
    # was still lstat).
    private def stat_follow(path : String) : LibC::Stat?
      stat = uninitialized LibC::Stat
      result = LibC.stat(path, pointerof(stat))
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
