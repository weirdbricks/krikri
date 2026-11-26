#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  # Filesystem plugin - creates (or wipes) a filesystem via the
  # appropriate `mkfs.*`/`mkswap`/`pvcreate` command, matching (a
  # pragmatic subset of) community.general.filesystem.
  #
  # Entirely unimplemented before - robertdebock.swap's own "Make swap
  # file system" task (fstype: swap on a freshly dd'd swap file)
  # silently dropped while Ansible actually ran mkswap.
  #
  # `resizefs:` and the post-create `uuid:` reset of an already-matching
  # filesystem are not implemented (Ansible module's own resize/UUID-reset
  # paths per fstype) - same class of documented, narrow scope cut as this
  # repo's other RHEL/FreeBSD-only module gaps. `uuid:` ON CREATION is
  # implemented: the create path's argv has to carry the same `-U <uuid>`
  # real's create() appends, since that argv is what a failed mkfs reports
  # back as `cmd` (kpg round, issue #1855).
  # `ufs` IS in the accepted choices (real filesystem.py's FILESYSTEMS
  # has UFS with MKFS=newfs) but creating one only works on FreeBSD.
  class FilesystemPlugin < BasePlugin
    PARAM_ALIASES = {
      "device" => "dev",
      "type"   => "fstype",
    }

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
      "ufs"      => {["newfs"], [] of String, "ufs"},
    }

    # Real filesystem.py's F2fs and Btrfs subclasses resolve their mkfs
    # binary in __init__ (get_bin_path(required=True)), and main()
    # instantiates the class right after reading blkid's TYPE - before
    # the same-fs branch, and in check mode too. A host without the
    # binary therefore fails the task where krikri's check-mode shortcut
    # used to answer "changed" (#1856, kpg
    # 000018-multi-dpkg_divert-happy's --check run).
    FSTYPE_INIT_BINARIES = {
      "f2fs"  => "mkfs.f2fs",
      "btrfs" => "mkfs.btrfs",
    }

    # Per-fstype `-U <uuid>` flag list (real filesystem.py's
    # MKFS_SET_UUID_OPTIONS on each class - the Ext classes share one,
    # bcachefs and LVM their own doubles). A fstype with neither this nor a
    # CHANGE_UUID command refuses `uuid:` outright rather than silently
    # formatting without it.
    MKFS_UUID_OPTIONS = {
      "ext2"     => ["-U"],
      "ext3"     => ["-U"],
      "ext4"     => ["-U"],
      "ext4dev"  => ["-U"],
      "bcachefs" => ["-U", "--uuid"],
      "lvm"      => ["-u", "--uuid"],
    }

    # Fstypes whose existing filesystem can be re-uuid'd after creation
    # (real's CHANGE_UUID: tune2fs/xfs_admin/pvchange) - only the
    # "is uuid supported at all" test needs them here, since that
    # post-create path itself is still unimplemented.
    CHANGE_UUID_FSTYPES = %w[ext2 ext3 ext4 ext4dev xfs lvm]

    def initialize(config : JSON::Any)
      super(config)
      PARAM_ALIASES.each do |alias_name, canonical|
        if (value = @params[alias_name]?) && !@params.has_key?(canonical)
          @params[canonical] = value
        end
      end
    end

    def execute : PluginResult
      dev = @params["dev"]?
      unless dev
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: dev")
      end

      state = @params["state"]?.try { |str| str.empty? ? nil : str } || "present"
      # Ansible's argument_spec gives state/fstype choices lists, so
      # AnsibleModule's choice check (parameters.py's exact wording)
      # fires before anything else param-wise - previously a bogus
      # state silently behaved as present and a bogus fstype fell
      # through to the device/blkid checks first. Ansible's choice list
      # is set-ordered (nondeterministic wording across runs); the
      # set of choices matches (minus FreeBSD-only ufs) and the
      # podman-diff case only compares failed=/changed= here.
      unless ["present", "absent"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got: #{state}")
      end

      fstype = @params["fstype"]?
      if error = validate_state_fstype(state, fstype)
        return error
      end

      force = true?(@params["force"]?)
      opts = @params["opts"]?.try(&.split) || [] of String
      check_mode = true?(@params["_ansible_check_mode"]?)
      # Python's `if uuid` treats the argspec's own empty-string default the
      # same as an absent uuid.
      uuid = @params["uuid"]?
      uuid = nil if uuid.try(&.empty?)

      exists_result = remote_exec("test -e #{shell_quote(dev)}")
      unless exists_result[:exit_code] == 0
        return missing_device_result(dev, state)
      end

      blkid_result = remote_exec("blkid -c /dev/null -o value -s TYPE #{shell_quote(dev)}")
      current_fs = blkid_result[:stdout].strip

      return absent_result(dev, current_fs, check_mode) if state == "absent"

      # state's choices leave only "present" here, and required_if
      # already guaranteed fstype for present.
      if fstype.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: fstype")
      end
      present_result(
        dev, current_fs, state, fstype, force, opts, uuid, check_mode,
        blkid_result[:exit_code], blkid_result[:stderr],
      )
    end

    # Ansible's argument_spec gives state/fstype choices lists, so
    # AnsibleModule's choice check (parameters.py's exact wording)
    # fires before anything else param-wise - previously a bogus
    # state silently behaved as present and a bogus fstype fell
    # through to the device/blkid checks first. Ansible's choice list
    # is set-ordered (nondeterministic wording across runs); the
    # set of choices matches (minus FreeBSD-only ufs) and the
    # podman-diff case only compares failed=/changed= here.
    private def validate_state_fstype(state : String, fstype : String?) : PluginResult?
      unless ["present", "absent"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got: #{state}")
      end

      if fstype && !FSTYPE_COMMANDS.has_key?(fstype)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of fstype must be one of: #{FSTYPE_COMMANDS.keys.sort!.join(", ")}, got: #{fstype}")
      end

      # required_if=[('state', 'present', ['fstype'])] - and real
      # AnsibleModule's required_if check runs before the module body,
      # so even a nonexistent dev with no fstype reports the missing
      # parameter, not "Device ... not found.".
      if state == "present" && !fstype
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: fstype")
      end
      nil
    end

    private def missing_device_result(dev : String, state : String) : PluginResult
      if state == "present"
        PluginResult.new(changed: false, failed: true, msg: "Device #{dev} not found.")
      else
        # Real state=absent dev-not-found exits exit_json(msg=msg): the
        # module dict carries only msg, and the controller backfills
        # changed:false after it - live-verified 2.19.11 wire order
        # [msg, changed].
        PluginResult.new(changed: false, failed: false, msg: "Device #{dev} not found.",
          key_order: ["msg", "changed"])
      end
    end

    # Real filesystem.py's success exits are exit_json(changed=changed)
    # with no msg key at all (absent: unchanged/wipefs; present:
    # already-same-fs/create) - live-verified 2.19.11.
    private def fs_success(changed : Bool) : PluginResult
      PluginResult.new(changed: changed, failed: false, key_order: ["changed"])
    end

    private def absent_result(dev : String, current_fs : String, check_mode : Bool) : PluginResult
      return fs_success(false) if current_fs.empty?
      return fs_success(true) if check_mode

      wipefs = find_required_binary("wipefs")
      return missing_binary_result("wipefs") unless wipefs

      argv = [wipefs, "--all", dev]
      wipe_result = remote_exec(argv.map { |itm| shell_quote(itm) }.join(' '))
      unless wipe_result[:exit_code] == 0
        return check_rc_failure(argv, wipe_result)
      end
      fs_success(true)
    end

    # basic.py's run_command(check_rc=True) exit: fail_json(msg=the
    # rstripped stderr, cmd=the shlex-quoted argv, rc/stdout/stderr and the
    # controller's *_lines). Real filesystem.py lets that shape through
    # untouched for both mkfs and wipefs - it never wraps the tool's own
    # message in a "<cmd> failed: " label, and a role that ignores the
    # error still reads `msg`/`rc`/`cmd`/`stderr` from the registered
    # result (kpg 000010-multi-flatpak-happy, issue #1855).
    private def check_rc_failure(
      argv : Array(String),
      result : NamedTuple(exit_code: Int32, stdout: String, stderr: String),
    ) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: result[:stderr].rstrip,
        cmd: argv.map { |itm| Shell.quote_arg(itm) }.join(' '),
        rc: result[:exit_code],
        stdout: result[:stdout], stdout_lines: result[:stdout].lines.map(&.chomp),
        stderr: result[:stderr], stderr_lines: result[:stderr].lines.map(&.chomp),
        key_order: ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines"])
    end

    # Real filesystem.py's idempotency compares FILESYSTEMS values (the
    # per-fstype classes), not fstype strings: ext4 and ext4dev share
    # the Ext class, and blkid's "LVM2_member" is the lvm class - so an
    # existing ext4 fs with fstype=ext4dev is changed=False, not a
    # force-required conflict.
    private def fs_class_of(name : String) : String
      case name
      when "ext4dev"     then "ext4"
      when "LVM2_member" then "lvm"
      else                    name
      end
    end

    private def present_result(
      dev : String, current_fs : String, state : String, fstype : String,
      force : Bool, opts : Array(String), uuid : String?, check_mode : Bool,
      blkid_rc : Int32, blkid_err : String,
    ) : PluginResult
      command_info = FSTYPE_COMMANDS[fstype]
      mkfs_argv, force_flags, _blkid_name = command_info

      # The class instantiation real main() does here, including the
      # required-binary lookup its F2fs/Btrfs __init__ performs. It
      # precedes every idempotency branch, so a missing mkfs binary is a
      # failure even in check mode and even for an already-diverged
      # device.
      if (init_binary = FSTYPE_INIT_BINARIES[fstype]?)
        unless find_required_binary(init_binary)
          return PluginResult.new(changed: false, failed: true,
            msg: PluginHelpers::GetBinPath.missing_executable_error(init_binary, @bin_searched_paths))
        end
      end

      create_filesystem(
        dev, current_fs, fs_class_of(current_fs), fs_class_of(fstype), fstype,
        mkfs_argv, force_flags, opts, uuid, force, check_mode, blkid_rc, blkid_err,
      )
    end

    private def create_filesystem(
      dev : String, current_fs : String, current_fs_class : String, fstype_class : String, fstype : String,
      mkfs_argv : Array(String), force_flags : Array(String),
      opts : Array(String), uuid : String?, force : Bool, check_mode : Bool,
      blkid_rc : Int32, blkid_err : String,
    ) : PluginResult
      # real main() runs this refusal before its idempotency checks, so a
      # fstype with no way to take a uuid at all fails even when the device
      # already carries that same filesystem.
      if error = uuid_unsupported_result(fstype, uuid)
        return error
      end

      same_fs = !current_fs.empty? && current_fs_class == fstype_class
      if same_fs && !force
        return fs_success(false)
      elsif !current_fs.empty? && !same_fs && !force
        return already_used_result(dev, current_fs, blkid_rc, blkid_err)
      end

      # create()'s check-mode return comes before get_bin_path, so a host
      # without the mkfs tool still reports changed=true under --check.
      return fs_success(true) if check_mode

      mkfs = find_required_binary(mkfs_argv.first)
      return missing_binary_result(mkfs_argv.first) unless mkfs

      argv = [mkfs] + force_flags + mkfs_create_opts(fstype, uuid, opts) + [dev]
      mkfs_result = remote_exec(argv.map { |itm| shell_quote(itm) }.join(' '))
      return check_rc_failure(argv, mkfs_result) unless mkfs_result[:exit_code] == 0

      fs_success(true)
    end

    private def uuid_unsupported_result(fstype : String, uuid : String?) : PluginResult?
      return nil if uuid.nil?
      return nil if MKFS_UUID_OPTIONS.has_key?(fstype) || CHANGE_UUID_FSTYPES.includes?(fstype)

      PluginResult.new(changed: false, failed: true,
        msg: "module does not support UUID option for this filesystem (#{fstype}) yet.")
    end

    # Real filesystem.py's fail_json passes the blkid run_command result along
    # as rc/err kwargs (filesystem.py's `fail_json(msg=..., rc=rc, err=err)`),
    # so the registered result carries blkid's rc (0 whenever it identified a
    # filesystem at all) and its stderr (usually empty).
    private def already_used_result(
      dev : String, current_fs : String, blkid_rc : Int32, blkid_err : String,
    ) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "'#{dev}' is already used as #{current_fs}, use force=true to overwrite",
        rc: blkid_rc, err: blkid_err,
        key_order: %w[rc err failed msg changed exception])
    end

    # get_bin_path(MKFS, required=True): the module's own search order ($PATH
    # then the standard sbin dirs) and its failure text.
    private def missing_binary_result(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error(name, @bin_searched_paths))
    end

    # create() appends the uuid flag pair unless the task's own opts already
    # carry one of them, so `opts: -U xyz` is not doubled.
    private def mkfs_create_opts(fstype : String, uuid : String?, opts : Array(String)) : Array(String)
      mkfs_opts = opts.dup
      uuid_opt = MKFS_UUID_OPTIONS[fstype]?
      if uuid_opt && (given_uuid = uuid)
        mkfs_opts += [uuid_opt[0], given_uuid] if (uuid_opt & mkfs_opts).empty?
      end
      mkfs_opts
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::FilesystemPlugin.new(config)
plugin.run
