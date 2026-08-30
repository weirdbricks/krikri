#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Filesystem plugin - creates (or wipes) a filesystem via the
  # appropriate `mkfs.*`/`mkswap`/`pvcreate` command, matching (a
  # pragmatic subset of) community.general.filesystem.
  #
  # Entirely unimplemented before - robertdebock.swap's own "Make swap
  # file system" task (fstype: swap on a freshly dd'd swap file)
  # silently dropped while real Ansible actually ran mkswap.
  #
  # `resizefs:`/`uuid:` are not implemented (real module's own resize/
  # UUID-reset paths per fstype) - same class of documented, narrow
  # scope cut as this repo's other RHEL/FreeBSD-only module gaps.
  # `ufs` (FreeBSD-only) is not in FSTYPE_COMMANDS for the same reason.
  class FilesystemPlugin < BasePlugin
    # fstype -> {mkfs command argv (before force flags/opts/dev),
    # force flags, blkid's own TYPE value for an existing fs of this
    # kind - usually identical to fstype, except lvm (blkid reports
    # "LVM2_member") - matching real filesystem.py's FILESYSTEMS map
    # and each subclass's own MKFS/MKFS_FORCE_FLAGS.
    FSTYPE_COMMANDS = {
      "ext2"     => {["mkfs.ext2"], ["-F"], "ext2"},
      "ext3"     => {["mkfs.ext3"], ["-F"], "ext3"},
      "ext4"     => {["mkfs.ext4"], ["-F"], "ext4"},
      "ext4dev"  => {["mkfs.ext4"], ["-F"], "ext4dev"},
      "xfs"      => {["mkfs.xfs"], ["-f"], "xfs"},
      "btrfs"    => {["mkfs.btrfs"], ["-f"], "btrfs"},
      "reiserfs" => {["mkfs.reiserfs"], ["-q"], "reiserfs"},
      "f2fs"     => {["mkfs.f2fs"], ["-f"], "f2fs"},
      "ocfs2"    => {["mkfs.ocfs2"], ["-Fx"], "ocfs2"},
      "bcachefs" => {["mkfs.bcachefs"], ["--force"], "bcachefs"},
      "vfat"     => {["mkfs.vfat"], [] of String, "vfat"},
      "swap"     => {["mkswap"], ["-f"], "swap"},
      "lvm"      => {["pvcreate"], ["-f"], "LVM2_member"},
    }

    def execute : PluginResult
      dev = @params["dev"]?
      return PluginResult.new(changed: false, failed: true, msg: "dev is required") unless dev

      state = @params["state"]?.try { |str| str.empty? ? nil : str } || "present"
      force = true?(@params["force"]?)
      opts = @params["opts"]?.try(&.split) || [] of String
      check_mode = true?(@params["check_mode"]?)

      exists_result = remote_exec("test -e #{shell_quote(dev)}")
      unless exists_result[:exit_code] == 0
        return missing_device_result(dev, state)
      end

      blkid_result = remote_exec("blkid -c /dev/null -o value -s TYPE #{shell_quote(dev)}")
      current_fs = blkid_result[:stdout].strip

      return absent_result(dev, current_fs, check_mode) if state == "absent"

      present_result(dev, current_fs, state, force, opts, check_mode)
    end

    private def missing_device_result(dev : String, state : String) : PluginResult
      if state == "present"
        PluginResult.new(changed: false, failed: true, msg: "Device #{dev} not found.")
      else
        PluginResult.new(changed: false, failed: false, msg: "Device #{dev} not found.")
      end
    end

    private def absent_result(dev : String, current_fs : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "") if current_fs.empty?
      return PluginResult.new(changed: true, failed: false, msg: "") if check_mode

      wipe_result = remote_exec("wipefs --all #{shell_quote(dev)}")
      unless wipe_result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "wipefs failed: #{wipe_result[:stderr]}")
      end
      PluginResult.new(changed: true, failed: false, msg: "")
    end

    private def present_result(
      dev : String, current_fs : String, state : String,
      force : Bool, opts : Array(String), check_mode : Bool,
    ) : PluginResult
      fstype = @params["fstype"]? || @params["type"]?
      unless fstype
        return PluginResult.new(changed: false, failed: true, msg: "fstype is required when state=present")
      end

      command_info = FSTYPE_COMMANDS[fstype]?
      unless command_info
        return PluginResult.new(changed: false, failed: true, msg: "module does not support this filesystem (#{fstype}) yet.")
      end

      mkfs_argv, force_flags, blkid_name = command_info
      create_filesystem(dev, current_fs, blkid_name, mkfs_argv, force_flags, opts, force, check_mode)
    end

    private def create_filesystem(
      dev : String, current_fs : String, blkid_name : String,
      mkfs_argv : Array(String), force_flags : Array(String),
      opts : Array(String), force : Bool, check_mode : Bool,
    ) : PluginResult
      same_fs = !current_fs.empty? && current_fs == blkid_name
      if same_fs && !force
        return PluginResult.new(changed: false, failed: false, msg: "")
      elsif !current_fs.empty? && !same_fs && !force
        return PluginResult.new(changed: false, failed: true, msg: "'#{dev}' is already used as #{current_fs}, use force=true to overwrite")
      end

      return PluginResult.new(changed: true, failed: false, msg: "") if check_mode

      cmd = (mkfs_argv + force_flags + opts + [dev]).map { |itm| shell_quote(itm) }.join(' ')
      mkfs_result = remote_exec(cmd)
      unless mkfs_result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "#{mkfs_argv.first} failed: #{mkfs_result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "")
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::FilesystemPlugin.new(config)
plugin.run
