#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Mount plugin - manages /etc/fstab entries and (optionally) actually
  # mounts/unmounts a filesystem. Compatible with Ansible's
  # ansible.posix.mount module.
  #
  # Supported parameters:
  # - path: mount point (required)
  # - src / fstype: device and filesystem type (required when
  #   state: present or mounted, matching real Ansible's own
  #   required_if - confirmed via its actual argument_spec, not assumed)
  # - opts: mount options (default "defaults")
  # - dump / passno: fstab fields (default "0")
  # - boot: whether the filesystem mounts on boot (default true) - false
  #   appends "noauto" to opts, matching real Ansible's behavior exactly
  # - fstab: path to the fstab file (default /etc/fstab)
  # - backup: copy the fstab file to a timestamped backup before writing
  #   (default false)
  # - state: present | absent | absent_from_fstab | mounted | unmounted |
  #   remounted (required)
  # - check_mode: report what would change without writing anything or
  #   mounting/unmounting
  #
  # Fstab line format and idempotency logic (matched by `path`, comparing
  # src/fstype/opts/dump/passno) verified by reading the real
  # ansible.posix mount.py source directly, not assumed from docs -
  # updates the matching line in place (preserving every other line
  # byte-for-byte) rather than removing and re-appending.
  #
  # Native vs shell-out: the fstab file-editing calls (`cat` -> native
  # `File.read_lines(chomp: false)`, `cp` backup -> native `File.copy`,
  # `mkdir -p` -> native `Dir.mkdir_p`) are converted to native Crystal
  # for local connections, like the other file plugins - but, unlike
  # those, mount genuinely supports remote hosts (its fstab write path
  # already branches on `local_connection?`), so each one keeps an
  # SSH branch back to the shell command for non-local hosts, where a
  # native `File.*` call would read/write the control node's filesystem
  # instead of the target's. The actual `mount`/`umount`/`mountpoint`
  # calls are genuine system operations and stay shelled-out either way.
  #
  # state: remounted (Linux `mount -o remount[,opts] [-T fstab] path`,
  # verified against real ansible.posix mount.py's own `remount()`
  # function source, not assumed - the BSD `-u` variant isn't
  # implemented, Linux-only like the rest of this plugin) always reports
  # `changed: true` on success, matching real Ansible's own documented
  # behavior (a remount is inherently "did something," not a state
  # comparison). If `opts:` is given (and isn't the literal string
  # `"defaults"`) and the remount command itself fails, this fails with
  # real Ansible's own exact message rather than silently doing nothing -
  # verified against the source, not paraphrased. When `opts:` is
  # absent/`"defaults"` and the remount command fails instead (e.g. the
  # mount point isn't actually in `fstab` yet, which `remounted` expects
  # is exactly the common case where a fstab entry was just added in the
  # same task/play), real Ansible falls back to a full `umount` + `mount`
  # cycle using the fstab entry (a bare `mount <path>` with no `-t`/`-o`
  # consults fstab for the matching line) - implemented here too now, and
  # only fails for real if BOTH the remount attempt AND that fallback
  # cycle fail. No path in this plugin is exit-code-blind anymore -
  # every `mount`/`umount` invocation propagates a real command failure
  # as a task failure with the command's own stdout/stderr, matching
  # real ansible.posix.mount's verified `fail_json` behavior.
  #
  # state: ephemeral (`path`/`src`/`fstype` required, same as
  # `present`/`mounted` - verified against real Ansible's own
  # `required_if`) mounts without ever touching `fstab` at all, matching
  # real Ansible's own "The fstab is completely ignored" behavior -
  # `fstab:`/`backup:`/`dump:`/`passno:` are all accepted but silently
  # have no effect here, same as real Ansible. If the mount point isn't
  # currently mounted, this creates it (`mkdir -p`) and mounts for real
  # (`mount -t <fstype> -o <opts> <src> <path>`, `opts:` verified to still
  # get `boot: false`'s `noauto` treatment even though there's no fstab
  # entry to append it to - confirmed against real Ansible's own source,
  # which computes that unconditionally before the ephemeral-specific
  # fstab skip). If it's *already* mounted, real Ansible compares the
  # mount table's actual current source device against the requested
  # `src:` (a new `current_mount_source`, reading `/proc/mounts` - no
  # `findmnt` dependency, matching the same "no new binary requirement"
  # preference the rest of this codebase already has) - a match triggers
  # a remount (reusing the exact same `mount -o remount[,opts]` shape
  # `state: remounted` already implements above); a mismatch fails
  # clearly with real Ansible's own exact message rather than risking an
  # unwanted unmount/override, matching its own documented behavior:
  # "the module will fail to avoid unexpected unmount or mount point
  # override." Always `changed: true` on success either way (both the
  # fresh-mount and the source-matches-so-remount paths set it), matching
  # real Ansible's own documented behavior exactly - verified against its
  # source, not just the one-line doc summary.
  #
  # Not implemented: Solaris/BSD-specific vfstab handling (Linux fstab
  # format only), `opts_no_log`, `fstab` `backup`'s exact filename format
  # (a reasonable equivalent is used instead).
  class MountPlugin < BasePlugin
    # The exact stderr text ansible-core 2.19 renders for this
    # deprecation (msg + "This feature will be removed from ansible-core
    # version 2.23." + help_text), carried verbatim in the result's
    # `_ansible_core_deprecations` display marker.
    CORE_WARNINGS_DEPRECATION_TEXT = "Passing `warnings` to `exit_json` or `fail_json` is deprecated. " \
                                     "This feature will be removed from ansible-core version 2.23. " \
                                     "Use `AnsibleModule.warn` instead."

    DEFAULT_FSTAB = "/etc/fstab"

    def execute : PluginResult
      # Real ansible.posix.mount rejects ANY parameter outside its own
      # argument_spec at module-arg validation, before any action runs -
      # this engine silently ignored the unknown key and wrote the fstab
      # entry anyway (changed=true on a task real Ansible fails). Found
      # via the podman-diff mount_edge_cases M3 harness case; message
      # live-verified against the real module's own output for this exact
      # task. check_mode/diff_mode/_module_name/_verbosity/_environment
      # are engine-internal keys injected by the executor (see
      # build_plugin_config), not part of the real argument_spec, so none
      # are rejected. The parenthesized alias list mirrors real Ansible's msg (name).
      mount_supported = {"backup", "boot", "dump", "fstab", "fstype", "opts", "opts_no_log", "passno", "path", "src", "state", "name"}
      mount_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| mount_supported.includes?(k) || mount_internal.includes?(k) }
      unless unsupported.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.posix.mount) module: #{unsupported.sort.join(", ")}. " \
               "Supported parameters include: backup, boot, dump, fstab, fstype, opts, opts_no_log, " \
               "passno, path, src, state (name)."
        )
      end

      # `name:` is real Ansible's own documented alias for `path:` (the
      # module's original param name, predating `path:` - still commonly
      # used in real-world roles, e.g. geerlingguy.swap's own "Manage
      # swap file entry in fstab." task: `mount: {name: none, src: ...}`).
      path = @params["path"]? || @params["name"]?
      state = @params["state"]?
      unless path && state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path and state are both required")
      end
      path = expand_tilde(path)

      unless %w[present absent absent_from_fstab mounted unmounted remounted ephemeral].includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "state must be one of present, absent, absent_from_fstab, mounted, unmounted, remounted, ephemeral")
      end

      if %w[present mounted ephemeral].includes?(state) && !(@params["src"]? && @params["fstype"]?)
        return PluginResult.new(changed: false, failed: true, msg: "state is #{state} but all of the following are missing: src, fstype")
      end

      run(path, state)
    end

    private def run(path : String, state : String) : PluginResult
      fstab = @params["fstab"]? || DEFAULT_FSTAB
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real mount.py creates a missing fstab file BEFORE any state
      # handling (except ephemeral, which ignores fstab entirely), even
      # in check mode: `if not os.path.exists(args['fstab'])` - makedirs
      # the parent when missing, then `open(args['fstab'], 'a')`. A bare
      # relative filename has os.path.dirname() == '' and
      # os.makedirs('') raises FileNotFoundError - an UNCAUGHT module
      # exception real 2.19.11 surfaces as "Task failed: Module failed:
      # [Errno 2] No such file or directory: ''" (live-verified) -
      # emulated here the same way apt's python-apt SystemError is.
      unless state == "ephemeral"
        if failure = ensure_fstab_file(fstab)
          return failure
        end
      end

      case state
      when "present", "mounted" then run_present(path, state, fstab, check_mode)
      when "unmounted"          then run_unmounted(path, check_mode)
      when "remounted"          then ensure_remounted(path, check_mode)
      when "ephemeral"          then ensure_ephemeral(path, check_mode)
      else                           run_absent(path, state, fstab, check_mode)
      end
    end

    # Real mount.py's own pre-state fstab creation (runs even in check
    # mode - it is outside any check_mode guard). Returns a failure
    # PluginResult when real Ansible would have failed here, nil when
    # execution continues.
    private def ensure_fstab_file(fstab : String) : PluginResult?
      return nil if remote_file_exists?(fstab)

      # os.path.dirname('uybxfa') == '' (Crystal's File.dirname would say
      # "." - not the same contract); os.path.exists('') is False.
      dirname = fstab.includes?('/') ? File.dirname(fstab) : ""
      exists = dirname.empty? ? false : dir_exists?(dirname)
      unless exists
        if dirname.empty?
          # os.makedirs('') raises FileNotFoundError: uncaught, the module
          # crash real renders as "Task failed: Module failed: ..." in both
          # the [ERROR] block and the fatal msg.
          detail = "[Errno 2] No such file or directory: ''"
          return PluginResult.new(changed: false, failed: true,
            msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
        end
        if local_connection?
          Dir.mkdir_p(dirname)
        else
          remote_exec("mkdir -p #{shell_single_quote(dirname)}")
        end
      end

      if local_connection?
        begin
          File.touch(fstab)
        rescue e : File::AccessDeniedError
          return fstab_open_failure(fstab, permission: true, detail: e.message.to_s)
        rescue e
          return fstab_open_failure(fstab, permission: false, detail: e.message.to_s)
        end
      else
        result = remote_exec("touch #{shell_single_quote(fstab)}")
        if result[:exit_code] != 0
          return fstab_open_failure(fstab,
            permission: result[:stderr].includes?("Permission denied"),
            detail: result[:stderr])
        end
      end
      nil
    end

    # Real's two open-failure fail_json texts.
    private def fstab_open_failure(fstab : String, permission : Bool, detail : String) : PluginResult
      if permission
        PluginResult.new(changed: false, failed: true,
          msg: "Failed to open #{fstab} due to permission issue")
      else
        PluginResult.new(changed: false, failed: true,
          msg: "Failed to open #{fstab} due to #{detail}")
      end
    end

    private def dir_exists?(path : String) : Bool
      if local_connection?
        Dir.exists?(path)
      else
        remote_exec("test -d #{shell_single_quote(path)}")[:exit_code] == 0
      end
    end

    private def run_present(path : String, state : String, fstab : String, check_mode : Bool) : PluginResult
      pre_lines = read_fstab(fstab)
      fstab_changed, backup_file = set_fstab_entry(path, fstab, check_mode)
      if state == "mounted"
        path_existed = remote_file_exists?(path)
        mount_changed, error = ensure_mounted(path, check_mode)
        # Real mount's failures are all bare fail_json(msg=...) - no
        # name/fstab/backup_file echo, and NO changed either: fail_json's
        # default is changed=False, so a mount that fails AFTER the fstab
        # entry was written still reports changed: false (the fstab edit
        # is not counted) - live-verified vs 2.19.11 with an unknown
        # fstype (mount(8) rejects it after the fstab write succeeded).
        if error
          # Real mount.py restores the pre-edit fstab (write_fstab with
          # the backup lines) and rmdirs the mountpoint dirs it created
          # when the mount command fails - "A non-working fstab entry may
          # break the system at the reboot, so undo all the changes if
          # possible" (ansible/ansible#59183). Without the restore the
          # entry lingers and a later state=absent cleanup task reports
          # changed where real reports ok (round 993003 kop_storage cold
          # recap: the /var/tmp/kop_mntfail cleanup loop item). Both
          # undo steps swallow failures, as real's try/except does.
          if fstab_changed && !check_mode
            begin
              write_fstab(fstab, pre_lines)
            rescue
              nil
            end
          end
          if !path_existed && !check_mode
            begin
              remote_exec("rmdir #{shell_single_quote(path)}")
            rescue
              nil
            end
          end
          return PluginResult.new(changed: false, failed: true, msg: error || "mount failed")
        end
      else
        mount_changed = false
      end
      success_result(fstab_changed || mount_changed, path, fstab, backup_file)
    end

    private def run_unmounted(path : String, check_mode : Bool) : PluginResult
      changed, error = ensure_unmounted(path, check_mode)
      return PluginResult.new(changed: false, failed: true, msg: error) if error
      success_result(changed, path, @params["fstab"]? || DEFAULT_FSTAB, "", include_src_fstype: false)
    end

    private def run_absent(path : String, state : String, fstab : String, check_mode : Bool) : PluginResult
      fstab_changed, backup_file = remove_fstab_entry(path, fstab, check_mode)
      if state == "absent"
        unmount_changed, error = ensure_unmounted(path, check_mode)
        # Same fail_json shape as run_present: changed defaults to False
        # on every real failure, even one after an fstab edit.
        return PluginResult.new(changed: false, failed: true, msg: error || "mount failed") if error
      else
        unmount_changed = false
      end
      success_result(fstab_changed || unmount_changed, path, fstab, backup_file)
    end

    # Real ansible.posix.mount echoes the effective fstab fields back in
    # every successful result. Verified live against real ansible
    # (ansible.posix 2.2.2 ad-hoc CLI comparison, privileged podman
    # container, 2026-09-13): every success carries name (the mount
    # point), fstab, backup_file ("" when none was created), boot
    # ("yes"/"no"), opts, dump, and passno - with src and fstype
    # included whenever the task actually passed those params (real
    # only copies `module.params[key]` into its args dict when it is
    # not None, so an absent fstype param means NO fstype key in the
    # result at all, not an empty string - re-verified 2026-09-29 with
    # state=absent/unmounted tasks passing src but no fstype). The
    # values are threaded through the fields the plugin already
    # computed to build/edit the fstab entry (desired_fields), not
    # recomputed.
    private def result_fields(path : String, fstab : String, backup_file : String, include_src_fstype : Bool = true) : Hash(String, String)
      desired = desired_fields(path)
      fields = {
        "name"        => path,
        "fstab"       => fstab,
        "backup_file" => backup_file,
        "boot"        => true?(@params["boot"]?, default: true) ? "yes" : "no",
        "opts"        => desired[3],
        "dump"        => desired[4],
        "passno"      => desired[5],
      }
      fields["src"] = desired[0] if include_src_fstype && @params["src"]?
      fields["fstype"] = desired[2] if include_src_fstype && @params["fstype"]?
      fields
    end

    private def success_result(changed : Bool, path : String, fstab : String, backup_file : String, msg : String = "", include_src_fstype : Bool = true) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, msg: msg)
      result_fields(path, fstab, backup_file, include_src_fstype).each do |key, value|
        result.extra[key] = JSON::Any.new(value)
      end
      # Real mount.py's single success exit is
      # `module.exit_json(changed=changed, **args)` with args ordered
      # name, opts, dump, passno, fstab, boot, backup_file, then the
      # user-specified src/fstype overrides appended (live-verified
      # against real 2.19.11 via a registered {{ r | to_json }} dump in
      # the podman container: state=absent, changed and unchanged runs
      # and check mode all identical).
      result.key_order = ["changed", "name", "opts", "dump", "passno", "fstab", "boot", "backup_file", "src", "fstype"]
      add_exit_json_warnings_deprecation(result)
      result
    end

    # Real mount keeps a `warnings` list in the args dict it passes to
    # its single `module.exit_json(changed=changed, **args)` success
    # exit (ansible.posix 2.x mount.py) - and ansible-core 2.19's
    # `_return_formatted` deprecates any `warnings` key passed to
    # exit_json/fail_json outright. The deprecation rides every
    # successful module run: the controller prints the "Deprecation
    # warnings can be disabled" hint plus the [DEPRECATION WARNING] line
    # (see ResultDisplay's `_ansible_core_deprecations` handling), while
    # the result's own `deprecations` list still carries the structured
    # entry into registered vars (both live-verified against 2.19.11).
    # Real's fail_json paths don't pass args, so failed results carry no
    # deprecation.
    private def add_exit_json_warnings_deprecation(result : PluginResult) : Nil
      result.extra["deprecations"] = JSON.parse([{
        "collection_name" => "ansible.builtin",
        "deprecator"      => {"resolved_name" => "ansible.builtin", "type" => nil},
        "msg"             => "Passing `warnings` to `exit_json` or `fail_json` is deprecated.",
        "version"         => "2.23",
      }].to_json)
      result.extra["_ansible_core_deprecations"] = JSON.parse([CORE_WARNINGS_DEPRECATION_TEXT].to_json)
    end

    private def desired_opts : String
      opts = @params["opts"]? || "defaults"
      return opts if true?(@params["boot"]?, default: true)

      parts = opts.split(",")
      parts << "noauto" unless parts.includes?("noauto")
      parts.join(",")
    end

    # Reads `fstab`, updates (or appends) the line for `path`, and writes
    # it back only if something actually changed - matching real
    # Ansible's field-by-field comparison (src/fstype/opts/dump/passno),
    # not a whole-line string comparison, so unrelated formatting in an
    # existing line (extra whitespace, a trailing comment) isn't churned.
    private def desired_fields(path : String) : Array(String)
      src = @params["src"]? || ""
      fstype = @params["fstype"]? || ""
      dump = @params["dump"]? || "0"
      passno = @params["passno"]? || "0"
      [src, path, fstype, desired_opts, dump, passno]
    end

    private def matches_desired?(fields : Array(String), desired : Array(String)) : Bool
      fields[0] == desired[0] && fields[2] == desired[2] && fields[3] == desired[3] &&
        fields[4] == desired[4] && fields[5] == desired[5]
    end

    private def set_fstab_entry(path : String, fstab : String, check_mode : Bool) : {Bool, String}
      desired = desired_fields(path)
      lines = read_fstab(fstab)
      found = false
      changed = false

      new_lines = lines.map do |line|
        fields = fstab_fields(line)
        next line unless fields && fields[1] == path

        found = true
        if matches_desired?(fields, desired)
          line
        else
          changed = true
          desired.join(" ") + "\n"
        end
      end

      unless found
        new_lines << desired.join(" ") + "\n"
        changed = true
      end

      persist_fstab(fstab, new_lines, changed, check_mode)
    end

    private def persist_fstab(fstab : String, lines : Array(String), changed : Bool, check_mode : Bool) : {Bool, String}
      backup_file = ""
      if changed && !check_mode
        backup_file = backup_fstab(fstab) if true?(@params["backup"]?)
        write_fstab(fstab, lines)
      end

      {changed, backup_file}
    end

    private def remove_fstab_entry(path : String, fstab : String, check_mode : Bool) : {Bool, String}
      lines = read_fstab(fstab)
      changed = false

      new_lines = lines.reject do |line|
        fields = fstab_fields(line)
        matches = fields && fields[1] == path
        changed = true if matches
        matches
      end

      persist_fstab(fstab, new_lines, changed, check_mode)
    end

    private def read_fstab(fstab : String) : Array(String)
      return [] of String unless remote_file_exists?(fstab)
      if local_connection?
        # chomp: false so the trailing newline is kept on every line,
        # letting `lines.join` in write_fstab reproduce the file
        # byte-for-byte (same contract the old `cat ... | lines(chomp:
        # false)` satisfied).
        File.read_lines(fstab, chomp: false)
      else
        remote_exec("cat #{shell_single_quote(fstab)}")[:stdout].lines(chomp: false)
      end
    end

    private def write_fstab(fstab : String, lines : Array(String)) : Nil
      content = lines.join
      if local_connection?
        File.write(fstab, content)
      else
        tmp = File.tempname
        File.write(tmp, content)
        remote_upload(tmp, fstab)
        File.delete(tmp)
      end
    end

    # Naming matches real ansible's backup_local() helper (used by
    # mount.py's backup): <fstab>.<file-owner-uid>.<YYYY-MM-DD@HH:MM:SS>~
    # - live-verified against real ansible 2026-09-13.
    private def backup_fstab(fstab : String) : String
      uid = remote_exec("stat -c %u #{shell_single_quote(fstab)}")[:stdout].strip
      backup_path = "#{fstab}.#{uid}.#{Time.local.to_s("%Y-%m-%d@%H:%M:%S")}~"
      if local_connection?
        File.copy(fstab, backup_path)
      else
        remote_exec("cp #{shell_single_quote(fstab)} #{shell_single_quote(backup_path)}")
      end
      backup_path
    end

    # Returns {src, name, fstype, opts, dump, passno} for a real fstab
    # line, or nil for a blank/comment line or one with an unexpected
    # field count.
    private def fstab_fields(line : String) : Array(String)?
      stripped = line.split('#').first.strip
      return nil if stripped.empty?

      fields = stripped.split
      return nil unless {4, 5, 6}.includes?(fields.size)

      fields << "0" if fields.size == 4
      fields << "0" if fields.size == 5
      fields
    end

    private def currently_mounted?(path : String) : Bool
      remote_exec("mountpoint -q #{shell_single_quote(path)}")[:exit_code] == 0
    end

    # Returns {changed, error_message_or_nil}. Proactive audit fix (the
    # same "real command failure silently discarded" shape found and
    # fixed elsewhere this same pass, in sysctl.cr/unarchive.cr/
    # apt_repository.cr) - the actual `mount`/`umount` command's exit
    # code used to be discarded entirely, so a genuinely failed mount
    # (wrong fstype, busy device, nonexistent src, ...) still reported
    # `changed: true, failed: false` as if it had succeeded. Real
    # ansible.posix.mount fails the task with the mount/umount command's
    # own stderr when it fails - verified against its actual source
    # (`module.fail_json(msg="Error mounting %s: %s" % (name, out +
    # err))`), not assumed.
    private def ensure_mounted(path : String, check_mode : Bool) : {Bool, String?}
      return {false, nil} if currently_mounted?(path)
      return {true, nil} if check_mode

      if local_connection?
        Dir.mkdir_p(path)
      else
        remote_exec("mkdir -p #{shell_single_quote(path)}")
      end
      src = @params["src"]? || ""
      fstype = @params["fstype"]? || ""
      opts = desired_opts
      result = remote_exec("mount -t #{shell_single_quote(fstype)} -o #{shell_single_quote(opts)} #{shell_single_quote(src)} #{shell_single_quote(path)}")
      return {false, "Error mounting #{path}: #{result[:stdout]}#{result[:stderr]}"} if result[:exit_code] != 0

      {true, nil}
    end

    private def ensure_unmounted(path : String, check_mode : Bool) : {Bool, String?}
      return {false, nil} unless currently_mounted?(path)
      return {true, nil} if check_mode

      result = remote_exec("umount #{shell_single_quote(path)}")
      return {false, "Error unmounting #{path}: #{result[:stdout]}#{result[:stderr]}"} if result[:exit_code] != 0

      {true, nil}
    end

    # `mount -o remount[,opts] [-T fstab] path` - always changed: true on
    # success (a remount is inherently "did something," matching real
    # Ansible's own documented RV(ignore:changed=true) here), verified
    # command shape and failure message against real ansible.posix
    # mount.py's own remount() source - see the class doc above for what
    # isn't replicated (the opts-absent-and-failed umount+mount fallback).
    private def ensure_remounted(path : String, check_mode : Bool) : PluginResult
      return success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "") if check_mode

      opts = @params["opts"]?
      custom_opts = opts && opts != "defaults"
      fstab = @params["fstab"]?

      cmd = String.build do |cmd_builder|
        cmd_builder << "mount -o "
        cmd_builder << shell_single_quote(custom_opts ? "remount,#{opts}" : "remount")
        cmd_builder << " -T #{shell_single_quote(fstab.to_s)}" if fstab && fstab != DEFAULT_FSTAB
        cmd_builder << " " << shell_single_quote(path)
      end

      result = remote_exec(cmd)
      if result[:exit_code] != 0
        if custom_opts
          # Real remount()'s fail_json here is msg-only - no name echo.
          return PluginResult.new(
            changed: false, failed: true,
            msg: "Options were specified with remounted, but the remount command failed. " \
                 "Failing in order to prevent an unexpected mount result. Try replacing this " \
                 "command with a \"state: unmounted\" followed by a \"state: mounted\" using " \
                 "the full desired mount options instead."
          )
        end

        # `opts:` absent/`"defaults"`: real ansible.posix mount.py's own
        # `remount()` falls back to a full `umount` + `mount` cycle
        # (both driven by the existing fstab entry - a bare `mount
        # <path>` with no `-t`/`-o` consults fstab for the matching
        # line's fstype/opts) rather than failing outright, since a bare
        # `mount -o remount` can genuinely fail for a mount point that
        # isn't actually in fstab yet (exactly the case `remounted` is
        # commonly used for right after adding the fstab entry in the
        # same task/play). Previously this whole fallback wasn't
        # implemented at all - a failed opts-less remount always
        # reported `changed: true, failed: false` regardless, matching
        # neither real Ansible's fallback NOR a real failure.
        return remount_via_umount_mount(path, fstab)
      end

      success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "")
    end

    # Real mount.py: remount()'s umount+mount fallback returns (rc, msg)
    # to main, whose remounted branch fails with
    # "Error remounting %s: %s" (name, out+err) - NOT "Error
    # unmounting"/"Error mounting" (those texts belong to the absent/
    # mounted states' own fail_json calls). msg-only, no name echo.
    private def remount_via_umount_mount(path : String, fstab : String?) : PluginResult
      umount_result = remote_exec("umount #{shell_single_quote(path)}")
      if umount_result[:exit_code] != 0
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Error remounting #{path}: #{umount_result[:stdout]}#{umount_result[:stderr]}"
        )
      end

      mount_cmd = String.build do |cmd_builder|
        cmd_builder << "mount"
        cmd_builder << " -T #{shell_single_quote(fstab.to_s)}" if fstab && fstab != DEFAULT_FSTAB
        cmd_builder << " " << shell_single_quote(path)
      end

      mount_result = remote_exec(mount_cmd)
      if mount_result[:exit_code] != 0
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Error remounting #{path}: #{mount_result[:stdout]}#{mount_result[:stderr]}"
        )
      end

      success_result(true, path, fstab || DEFAULT_FSTAB, "")
    end

    # Mounts without ever touching fstab - see the class doc above for
    # the full breakdown. `src`/`fstype` are guaranteed present by
    # #execute's own validation before this is ever called.
    private def ensure_ephemeral(path : String, check_mode : Bool) : PluginResult
      src = @params["src"]? || ""
      fstype = @params["fstype"]? || ""

      if currently_mounted?(path)
        return ensure_ephemeral_remount(path, src, fstype, check_mode)
      end

      return success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "", msg: "Would mount (check mode)") if check_mode

      if local_connection?
        Dir.mkdir_p(path)
      else
        remote_exec("mkdir -p #{shell_single_quote(path)}")
      end

      result = remote_exec("mount -t #{shell_single_quote(fstype)} -o #{shell_single_quote(desired_opts)} #{shell_single_quote(src)} #{shell_single_quote(path)}")
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "Error mounting #{path}: #{result[:stdout]}#{result[:stderr]}")
      end

      success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "")
    end

    # Real Ansible compares the mount table's actual current source
    # device against the requested src: before touching an already-
    # mounted ephemeral mount point - a match triggers a remount, a
    # mismatch fails clearly rather than risking an unwanted unmount or
    # override of a mount point this task doesn't actually own.
    private def ensure_ephemeral_remount(path : String, src : String, fstype : String, check_mode : Bool) : PluginResult
      unless current_mount_source(path) == src
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Ephemeral mount point is already mounted with a different source than the specified one. " \
               "Failing in order to prevent an unwanted unmount or override operation. Try replacing this " \
               "command with a \"state: unmounted\" followed by a \"state: ephemeral\", or use a different " \
               "destination path."
        )
      end

      return success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "") if check_mode

      result = remote_exec(ephemeral_remount_command(path, src, fstype))
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "Error mounting #{path}: #{result[:stdout]}#{result[:stderr]}")
      end

      success_result(true, path, @params["fstab"]? || DEFAULT_FSTAB, "")
    end

    # `mount -o remount -t <fstype> [-o <opts>] <src> <path>` - a
    # distinctly different shape from state: remounted's own `mount -o
    # remount[,opts] [-T fstab] path`, verified against real Ansible's
    # own `remount()` source: for `state: ephemeral` specifically, the
    # `-o remount` from the opts-aware branch (only taken for
    # `state: remounted`) is skipped in favor of a second, separate
    # `-o <opts>` coming from the same `_set_ephemeral_args` helper the
    # fresh-mount path above also uses, and `fstype`/`src` are appended
    # too (real Ansible's own `remount()` needs both regardless of
    # `state:`, since `mount -o remount` alone can't re-derive them the
    # way an fstab-backed remount can).
    private def ephemeral_remount_command(path : String, src : String, fstype : String) : String
      opts = desired_opts
      String.build do |cmd|
        cmd << "mount -o remount -t " << shell_single_quote(fstype)
        cmd << " -o " << shell_single_quote(opts) if opts != "defaults"
        cmd << " " << shell_single_quote(src) << " " << shell_single_quote(path)
      end
    end

    # Reads /proc/mounts (no `findmnt` dependency, matching this
    # codebase's general preference for not requiring extra binaries)
    # for the source device currently mounted at *path*, or nil if
    # nothing is.
    private def current_mount_source(path : String) : String?
      content = local_connection? ? read_proc_mounts : remote_exec("cat /proc/mounts")[:stdout]

      content.each_line do |line|
        fields = line.split
        next unless fields.size >= 2 && fields[1] == path
        return fields[0]
      end

      nil
    end

    private def read_proc_mounts : String
      File.exists?("/proc/mounts") ? File.read("/proc/mounts") : ""
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MountPlugin.new(config)
plugin.run
