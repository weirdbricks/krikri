require "../minitest_helper"
require "file_utils"

# The classic suite pre-created a shared spec/tmp/mount dir in
# before_suite; every test now gets its own tmp_path subtree.
private def fresh_fstab(name : String, seed : String = "") : String
  path = PluginSpecHelper.tmp_path(name)
  File.write(path, seed)
  path
end

describe "mount plugin" do
  it "appends a new fstab entry with defaults for opts/dump/passno" do
    fstab = fresh_fstab("append.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.must_equal(true)
    File.read(fstab).must_equal("UUID=abc / ext4 errors=remount-ro 0 1\n/dev/sdb1 /mnt/data ext4 defaults 0 0\n")
  end

  it "accepts name: as a documented alias for path:" do
    # Real bug found benchmarking geerlingguy.swap's own "Manage swap
    # file entry in fstab." task: `mount: {name: none, src: ..., fstype:
    # swap, ...}` - `name:` is Ansible's own original param name
    # for the mount module (predating `path:`, still a documented and
    # commonly-used alias). Only `path:` was ever read, so this always
    # failed outright with "missing required argument: path and state
    # are both required" even though both were given, just as `name:`/
    # `state:`.
    fstab = fresh_fstab("name-alias.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "name" => "none", "src" => "/swapfile", "fstype" => "swap", "opts" => "sw", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.must_equal(true)
    File.read(fstab).must_equal("UUID=abc / ext4 errors=remount-ro 0 1\n/swapfile none swap sw 0 0\n")
  end

  it "reports changed: false on an idempotent rerun" do
    fstab = fresh_fstab("idempotent.fstab")
    params = {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab}
    PluginSpecHelper.run("mount", params)

    result = PluginSpecHelper.run("mount", params)

    result["changed"].as_bool.must_equal(false)
  end

  it "updates the existing line in place when a field differs, preserving other lines byte-for-byte" do
    fstab = fresh_fstab("update.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")
    PluginSpecHelper.run("mount", {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab})

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "opts" => "ro,noatime", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.must_equal(true)
    File.read(fstab).must_equal("UUID=abc / ext4 errors=remount-ro 0 1\n/dev/sdb1 /mnt/data ext4 ro,noatime 0 0\n")
  end

  it "appends noauto to opts when boot: false" do
    fstab = fresh_fstab("boot-false.fstab")

    PluginSpecHelper.run("mount", {
      "path" => "/mnt/nfsdata", "src" => "192.168.1.1:/export", "fstype" => "nfs", "boot" => "false", "state" => "present", "fstab" => fstab,
    })

    File.read(fstab).must_include("defaults,noauto")
  end

  it "removes only the matching entry with state: absent_from_fstab" do
    fstab = fresh_fstab("remove.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")
    PluginSpecHelper.run("mount", {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab})

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/data", "state" => "absent_from_fstab", "fstab" => fstab})

    result["changed"].as_bool.must_equal(true)
    File.read(fstab).must_equal("UUID=abc / ext4 errors=remount-ro 0 1\n")
  end

  it "reports changed: false removing an entry that isn't present" do
    fstab = fresh_fstab("remove-noop.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/never-there", "state" => "absent_from_fstab", "fstab" => fstab})

    result["changed"].as_bool.must_equal(false)
  end

  it "fails with a clear message when src/fstype are missing for state: present" do
    fstab = fresh_fstab("missing-src.fstab")

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/x", "state" => "present", "fstab" => fstab})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("src")
  end

  it "fails with a clear message when path or state is missing" do
    result = PluginSpecHelper.run("mount", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("path")
  end

  # Ansible.posix.mount passes a `warnings` list to its single
  # exit_json success exit, and ansible-core 2.19's _return_formatted
  # deprecates that - every successful run carries the structured
  # `deprecations` entry into registered vars plus the display marker
  # ResultDisplay renders as the [DEPRECATION WARNING] stderr line
  # (captured live against 2.19.11). Ansible's fail_json paths don't pass
  # args, so failures carry neither.
  it "carries the exit_json warnings deprecation on every successful result" do
    fstab = fresh_fstab("deprecation.fstab")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/dep", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab,
    })

    deprecations = result["deprecations"].as_a
    deprecations.size.must_equal(1)
    entry = deprecations[0].as_h
    entry["msg"].as_s.must_equal("Passing `warnings` to `exit_json` or `fail_json` is deprecated.")
    entry["version"].as_s.must_equal("2.23")
    entry["collection_name"].as_s.must_equal("ansible.builtin")
    entry["deprecator"].as_h["resolved_name"].as_s.must_equal("ansible.builtin")
    result["_ansible_core_deprecations"].as_a.size.must_equal(1)
    result["_ansible_core_deprecations"].as_a[0].as_s.must_equal(
      "Passing `warnings` to `exit_json` or `fail_json` is deprecated. " \
      "This feature will be removed from ansible-core version 2.23. " \
      "Use `AnsibleModule.warn` instead.")
  end

  it "carries no deprecation on a failed result (Ansible's fail_json passes no args)" do
    fstab = fresh_fstab("deprecation-fail.fstab")

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/x", "state" => "present", "fstab" => fstab})

    result["failed"].as_bool.must_equal(true)
    result["deprecations"]?.must_be_nil
    result["_ansible_core_deprecations"]?.must_be_nil
  end

  it "omits src/fstype from the result when the task did not pass them (Ansible only copies non-None params)" do
    fstab = fresh_fstab("no-fstype-param.fstab")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/nofstype", "src" => "/dev/sdb1", "state" => "absent", "fstab" => fstab,
    })

    result["src"]?.must_equal("/dev/sdb1")
    result["fstype"]?.must_be_nil
  end

  it "reports it would mount (check mode, no real mount attempted) for a path that isn't currently mounted" do
    fstab = fresh_fstab("mounted-check.fstab")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "src" => "/dev/fake", "fstype" => "ext4", "state" => "mounted", "fstab" => fstab, "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
  end

  it "fails the task when the real mount command fails, instead of silently reporting changed: true (state: mounted)" do
    # Proactive audit fix (same "real command failure silently
    # discarded" shape found and fixed this pass in sysctl.cr/
    # unarchive.cr/apt_repository.cr): ensure_mounted used to discard
    # the mount command's own exit code entirely - a genuinely failed
    # mount (this spec sandbox has no CAP_SYS_ADMIN, so any real mount
    # attempt fails the same way an invalid fstype/src would on a
    # privileged host) still reported changed: true, failed: false as
    # if it had succeeded. Ansible.posix.mount fails the task with
    # the mount command's own stderr - verified against its actual
    # source, not assumed.
    fstab = fresh_fstab("mount-fail.fstab")
    mount_point = PluginSpecHelper.tmp_path("mount-fail-target")
    Dir.mkdir_p(mount_point)

    result = PluginSpecHelper.run("mount", {
      "path" => mount_point, "src" => "/dev/crystal_ansible_spec_fake_device",
      "fstype" => "ext4", "state" => "mounted", "fstab" => fstab,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mounting")
    # Real mount.py's failures are bare fail_json(msg=...) - fail_json's
    # changed default is False, so a mount that fails AFTER the fstab entry
    # was successfully written still reports changed: false (live-verified
    # vs 2.19.11 with an unknown fstype).
    result["changed"].as_bool.must_equal(false)
  end

  it "fails the task when the real umount command fails, instead of silently reporting changed: true (state: unmounted)" do
    # Same fix, the ensure_unmounted side: only reachable when
    # currently_mounted? is true, so this exercises it against a path
    # that's ACTUALLY mounted (the spec's own tmp dir's parent
    # filesystem root, "/" - already mounted by definition on any host)
    # with an unmount that will fail (no privilege in this sandbox).
    result = PluginSpecHelper.run("mount", {
      "path" => "/", "state" => "unmounted",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("unmounting")
  end

  it "state: absent reports changed: false when the umount fails after an fstab edit" do
    # The state: absent twin of the changed:false fix above: Ansible's
    # fail_json never passes changed, so an unmount failure AFTER
    # remove_fstab_entry edited the file reports changed: false, not the
    # fstab edit's own changed: true (live-verified vs 2.19.11).
    fstab = fresh_fstab("absent-umount-fail.fstab", "/ ext4 defaults 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/", "state" => "absent", "fstab" => fstab,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("unmounting")
    result["changed"].as_bool.must_equal(false)
  end

  it "does not actually write the fstab file in check mode (regression: check_mode only guarded the mount/umount step, not the fstab write)" do
    fstab = fresh_fstab("write-check.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "src" => "/dev/fake", "fstype" => "ext4", "state" => "present", "fstab" => fstab, "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(fstab).must_equal("UUID=abc / ext4 errors=remount-ro 0 1\n")
  end

  # state: remounted needs a genuinely already-mounted filesystem to
  # remount (verified for real separately - see git log - against a
  # real tmpfs mount inside a --privileged container, since the shared
  # CI/dev sandbox this spec suite runs in can't mount anything at all
  # without one), so only its check_mode path - which never touches a
  # real mount - is exercised here. Same convention state: mounted/
  # unmounted's own specs above already use.
  it "reports it would remount (check mode, no real remount attempted)" do
    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "state" => "remounted", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "fails with Ansible's exact message when opts: is given and the remount command fails" do
    result = PluginSpecHelper.run("mount", {
      "path" => "/", "state" => "remounted", "opts" => "ro",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Options were specified with remounted")
  end

  it "falls back to a real umount+mount cycle when opts: is absent and the remount command fails, matching Ansible's own fallback" do
    # Real bug this closes: when opts: is absent/"defaults" and a bare
    # `mount -o remount` fails (the common case right after adding a
    # fstab entry in the same task/play, before the mount point is
    # "really" mounted from fstab's point of view),
    # ansible.posix.mount doesn't fail outright - it falls back to a
    # full `umount` + `mount <path>` cycle (the second `mount` consults
    # fstab for the matching line). This plugin used to have no fallback
    # at all and just reported changed: true regardless, matching
    # neither a real success nor a real failure. Exercised here against
    # "/" (this sandbox has no privilege to remount/umount/mount it, so
    # both the initial remount AND the umount+mount fallback genuinely
    # fail) - no real mount state is touched either way, and the plugin
    # should now report a REAL failure instead of silently reporting
    # changed: true. Ansible's remounted-branch failure text is
    # "Error remounting %s: %s" with the FALLBACK command's output -
    # main()'s remounted branch wraps whatever remount() returned, it
    # never re-words it as "Error unmounting"/"Error mounting"
    # (mount.py source, live-verified vs 2.19.11).
    result = PluginSpecHelper.run("mount", {
      "path" => "/", "state" => "remounted",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("remounting")
  end

  # Real mount.py fails every mount/umount/remount error with a bare
  # fail_json(msg=...) - no name echo (live-verified vs 2.19.11 in a
  # privileged container: fatal => {"changed": false, "msg": "Error
  # mounting ...: mount: ... unknown filesystem type ..."}).
  it "fails a failed ephemeral mount with msg only - no name echo" do
    path = PluginSpecHelper.tmp_path("ephemeral-fail-mount")
    result = PluginSpecHelper.run("mount", {
      "path" => path, "src" => "/opt/kpg-fixtures/template.j2",
      "fstype" => "krikri_nonexistent_fs", "state" => "ephemeral",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?("Error mounting #{path}: ").must_equal(true)
    result.as_h.has_key?("name").must_equal(false)
  end

  # Real mount.py creates a missing fstab file before any state handling
  # (except ephemeral), even in check mode. A bare relative fstab
  # filename has os.path.dirname() == '' and os.makedirs('') raises
  # FileNotFoundError - an UNCAUGHT module exception Ansible 2.19.11
  # renders as "Task failed: Module failed: [Errno 2] No such file or
  # directory: ''" in both the [ERROR] block and the fatal msg
  # (live-verified). No fstab file may be left behind either.
  it "reproduces Ansible's uncaught os.makedirs('') crash for a bare relative fstab filename with state: remounted" do
    dir = PluginSpecHelper.tmp_path("remount-bare-fstab")
    FileUtils.mkdir_p(dir)

    result = PluginSpecHelper.run("mount", {
      "path" => File.join(dir, "sub"), "state" => "remounted", "fstab" => "uybxfa",
    }, chdir: dir)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: [Errno 2] No such file or directory: ''")
    result["_ansible_error_detail"].as_s.must_equal("[Errno 2] No such file or directory: ''")
    File.exists?(File.join(dir, "uybxfa")).must_equal(false)
  end

  # The same pre-state step's success side: a missing fstab under a
  # missing parent directory gets mkdir -p'd and touched before the
  # state handling runs - even in check mode (Ansible's creation block is
  # outside any check_mode guard).
  it "creates a missing fstab file and its parent directories before state handling, even in check mode" do
    fstab = PluginSpecHelper.tmp_path("nested", "dir", "created.fstab")
    FileUtils.rm_rf(PluginSpecHelper.tmp_path("nested", "dir"))

    result = PluginSpecHelper.run("mount", {
      "path" => PluginSpecHelper.tmp_path("nested-mount-point"), "state" => "remounted",
      "fstab" => fstab, "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.exists?(fstab).must_equal(true)
  end
end
