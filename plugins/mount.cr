#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
  # already branches on `is_local_connection?`), so each one keeps an
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
  # verified against the source, not paraphrased. One real behavior *not*
  # implemented: when `opts:` is absent/`"defaults"` and the remount
  # command fails (e.g. the mount point isn't actually in `fstab` yet,
  # which `remounted` expects), real Ansible falls back to a full
  # `umount` + `mount` cycle using the fstab entry; this plugin instead
  # just reports `changed: true` regardless, matching the existing
  # `ensure_mounted`/`ensure_unmounted` helpers' own exit-code-blind
  # convention rather than adding exit-code checking to only one state -
  # a documented simplification, not an oversight.
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
    DEFAULT_FSTAB = "/etc/fstab"

    def execute : PluginResult
      path = @params["path"]?
      state = @params["state"]?
      unless path && state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path and state are both required")
      end

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
      check_mode = is_true?(@params["check_mode"]?)

      case state
      when "present", "mounted"
        fstab_changed, backup_file = set_fstab_entry(path, fstab, check_mode)
        mount_changed = state == "mounted" ? ensure_mounted(path, check_mode) : false
        PluginResult.new(changed: fstab_changed || mount_changed, failed: false, msg: "", name: path, fstab: fstab, backup_file: backup_file)
      when "unmounted"
        changed = ensure_unmounted(path, check_mode)
        PluginResult.new(changed: changed, failed: false, msg: "", name: path)
      when "remounted"
        ensure_remounted(path, check_mode)
      when "ephemeral"
        ensure_ephemeral(path, check_mode)
      else
        fstab_changed, backup_file = remove_fstab_entry(path, fstab, check_mode)
        unmount_changed = state == "absent" ? ensure_unmounted(path, check_mode) : false
        PluginResult.new(changed: fstab_changed || unmount_changed, failed: false, msg: "", name: path, fstab: fstab, backup_file: backup_file)
      end
    end

    private def desired_opts : String
      opts = @params["opts"]? || "defaults"
      return opts if is_true?(@params["boot"]?, default: true)

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
        backup_file = backup_fstab(fstab) if is_true?(@params["backup"]?)
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
      if is_local_connection?
        # chomp: false so the trailing newline is kept on every line,
        # letting `lines.join` in write_fstab reproduce the file
        # byte-for-byte (same contract the old `cat ... | lines(chomp:
        # false)` satisfied).
        File.read_lines(fstab, chomp: false)
      else
        remote_exec("cat #{fstab}")[:stdout].lines(chomp: false)
      end
    end

    private def write_fstab(fstab : String, lines : Array(String))
      content = lines.join
      if is_local_connection?
        File.write(fstab, content)
      else
        tmp = File.tempname
        File.write(tmp, content)
        remote_upload(tmp, fstab)
        File.delete(tmp)
      end
    end

    private def backup_fstab(fstab : String) : String
      backup_path = "#{fstab}.#{Time.utc.to_unix}.bak"
      if is_local_connection?
        File.copy(fstab, backup_path)
      else
        remote_exec("cp #{fstab} #{backup_path}")
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
      remote_exec("mountpoint -q #{path}")[:exit_code] == 0
    end

    private def ensure_mounted(path : String, check_mode : Bool) : Bool
      return false if currently_mounted?(path)
      return true if check_mode

      if is_local_connection?
        Dir.mkdir_p(path)
      else
        remote_exec("mkdir -p #{path}")
      end
      src = @params["src"]? || ""
      fstype = @params["fstype"]? || ""
      opts = desired_opts
      remote_exec("mount -t #{fstype} -o #{opts} #{src} #{path}")
      true
    end

    private def ensure_unmounted(path : String, check_mode : Bool) : Bool
      return false unless currently_mounted?(path)
      return true if check_mode

      remote_exec("umount #{path}")
      true
    end

    # `mount -o remount[,opts] [-T fstab] path` - always changed: true on
    # success (a remount is inherently "did something," matching real
    # Ansible's own documented RV(ignore:changed=true) here), verified
    # command shape and failure message against real ansible.posix
    # mount.py's own remount() source - see the class doc above for what
    # isn't replicated (the opts-absent-and-failed umount+mount fallback).
    private def ensure_remounted(path : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "", name: path) if check_mode

      opts = @params["opts"]?
      custom_opts = opts && opts != "defaults"
      fstab = @params["fstab"]?

      cmd = String.build do |cmd_builder|
        cmd_builder << "mount -o remount"
        cmd_builder << ",#{opts}" if custom_opts
        cmd_builder << " -T #{fstab}" if fstab && fstab != DEFAULT_FSTAB
        cmd_builder << " " << path
      end

      result = remote_exec(cmd)
      if result[:exit_code] != 0 && custom_opts
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Options were specified with remounted, but the remount command failed. " \
               "Failing in order to prevent an unexpected mount result. Try replacing this " \
               "command with a \"state: unmounted\" followed by a \"state: mounted\" using " \
               "the full desired mount options instead.",
          name: path
        )
      end

      PluginResult.new(changed: true, failed: false, msg: "", name: path)
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

      return PluginResult.new(changed: true, failed: false, msg: "Would mount (check mode)", name: path) if check_mode

      if is_local_connection?
        Dir.mkdir_p(path)
      else
        remote_exec("mkdir -p #{path}")
      end

      remote_exec("mount -t #{fstype} -o #{desired_opts} #{src} #{path}")
      PluginResult.new(changed: true, failed: false, msg: "", name: path)
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
               "destination path.",
          name: path
        )
      end

      return PluginResult.new(changed: true, failed: false, msg: "", name: path) if check_mode

      remote_exec(ephemeral_remount_command(path, src, fstype))
      PluginResult.new(changed: true, failed: false, msg: "", name: path)
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
        cmd << "mount -o remount -t " << fstype
        cmd << " -o " << opts if opts != "defaults"
        cmd << " " << src << " " << path
      end
    end

    # Reads /proc/mounts (no `findmnt` dependency, matching this
    # codebase's general preference for not requiring extra binaries)
    # for the source device currently mounted at *path*, or nil if
    # nothing is.
    private def current_mount_source(path : String) : String?
      content = is_local_connection? ? read_proc_mounts : remote_exec("cat /proc/mounts")[:stdout]

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

plugin = CrystalPlay::MountPlugin.new(config)
plugin.run
