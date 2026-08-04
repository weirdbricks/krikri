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
  # - state: present | absent | absent_from_fstab | mounted | unmounted
  #   (required)
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
  # Not implemented: `remounted` and `ephemeral` states (rarer, and
  # `ephemeral` in particular has real Ansible's own device-source-conflict
  # checking logic that's out of scope here), Solaris/BSD-specific vfstab
  # handling (Linux fstab format only), `opts_no_log`, `fstab` `backup`'s
  # exact filename format (a reasonable equivalent is used instead).
  class MountPlugin < BasePlugin
    DEFAULT_FSTAB = "/etc/fstab"

    def execute : PluginResult
      path = @params["path"]?
      state = @params["state"]?
      unless path && state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path and state are both required")
      end

      unless %w[present absent absent_from_fstab mounted unmounted].includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "state must be one of present, absent, absent_from_fstab, mounted, unmounted")
      end

      if (state == "present" || state == "mounted") && !(@params["src"]? && @params["fstype"]?)
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
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::MountPlugin.new(config)
plugin.run
