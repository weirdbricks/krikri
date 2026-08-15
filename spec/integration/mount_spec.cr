require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "mount")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def fresh_fstab(name : String, seed : String = "") : String
  path = File.join(TMP_DIR, name)
  File.write(path, seed)
  path
end

describe "mount plugin" do
  it "appends a new fstab entry with defaults for opts/dump/passno" do
    fstab = fresh_fstab("append.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n/dev/sdb1 /mnt/data ext4 defaults 0 0\n")
  end

  it "accepts name: as a documented alias for path:" do
    # Real bug found benchmarking geerlingguy.swap's own "Manage swap
    # file entry in fstab." task: `mount: {name: none, src: ..., fstype:
    # swap, ...}` - `name:` is real Ansible's own original param name
    # for the mount module (predating `path:`, still a documented and
    # commonly-used alias). Only `path:` was ever read, so this always
    # failed outright with "missing required argument: path and state
    # are both required" even though both were given, just as `name:`/
    # `state:`.
    fstab = fresh_fstab("name-alias.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "name" => "none", "src" => "/swapfile", "fstype" => "swap", "opts" => "sw", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n/swapfile none swap sw 0 0\n")
  end

  it "reports changed: false on an idempotent rerun" do
    fstab = fresh_fstab("idempotent.fstab")
    params = {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab}
    PluginSpecHelper.run("mount", params)

    result = PluginSpecHelper.run("mount", params)

    result["changed"].as_bool.should be_false
  end

  it "updates the existing line in place when a field differs, preserving other lines byte-for-byte" do
    fstab = fresh_fstab("update.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")
    PluginSpecHelper.run("mount", {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab})

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "opts" => "ro,noatime", "state" => "present", "fstab" => fstab,
    })

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n/dev/sdb1 /mnt/data ext4 ro,noatime 0 0\n")
  end

  it "appends noauto to opts when boot: false" do
    fstab = fresh_fstab("boot-false.fstab")

    PluginSpecHelper.run("mount", {
      "path" => "/mnt/nfsdata", "src" => "192.168.1.1:/export", "fstype" => "nfs", "boot" => "false", "state" => "present", "fstab" => fstab,
    })

    File.read(fstab).should contain("defaults,noauto")
  end

  it "removes only the matching entry with state: absent_from_fstab" do
    fstab = fresh_fstab("remove.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")
    PluginSpecHelper.run("mount", {"path" => "/mnt/data", "src" => "/dev/sdb1", "fstype" => "ext4", "state" => "present", "fstab" => fstab})

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/data", "state" => "absent_from_fstab", "fstab" => fstab})

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n")
  end

  it "reports changed: false removing an entry that isn't present" do
    fstab = fresh_fstab("remove-noop.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/never-there", "state" => "absent_from_fstab", "fstab" => fstab})

    result["changed"].as_bool.should be_false
  end

  it "fails with a clear message when src/fstype are missing for state: present" do
    fstab = fresh_fstab("missing-src.fstab")

    result = PluginSpecHelper.run("mount", {"path" => "/mnt/x", "state" => "present", "fstab" => fstab})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("src")
  end

  it "fails with a clear message when path or state is missing" do
    result = PluginSpecHelper.run("mount", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("path")
  end

  it "reports it would mount (check mode, no real mount attempted) for a path that isn't currently mounted" do
    fstab = fresh_fstab("mounted-check.fstab")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "src" => "/dev/fake", "fstype" => "ext4", "state" => "mounted", "fstab" => fstab, "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
  end

  it "fails the task when the real mount command fails, instead of silently reporting changed: true (state: mounted)" do
    # Proactive audit fix (same "real command failure silently
    # discarded" shape found and fixed this pass in sysctl.cr/
    # unarchive.cr/apt_repository.cr): ensure_mounted used to discard
    # the mount command's own exit code entirely - a genuinely failed
    # mount (this spec sandbox has no CAP_SYS_ADMIN, so any real mount
    # attempt fails the same way an invalid fstype/src would on a
    # privileged host) still reported changed: true, failed: false as
    # if it had succeeded. Real ansible.posix.mount fails the task with
    # the mount command's own stderr - verified against its actual
    # source, not assumed.
    fstab = fresh_fstab("mount-fail.fstab")
    mount_point = File.join(TMP_DIR, "mount-fail-target")
    Dir.mkdir_p(mount_point)

    result = PluginSpecHelper.run("mount", {
      "path" => mount_point, "src" => "/dev/crystal_ansible_spec_fake_device",
      "fstype" => "ext4", "state" => "mounted", "fstab" => fstab,
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("mounting")
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("unmounting")
  end

  it "does not actually write the fstab file in check mode (regression: check_mode only guarded the mount/umount step, not the fstab write)" do
    fstab = fresh_fstab("write-check.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "src" => "/dev/fake", "fstype" => "ext4", "state" => "present", "fstab" => fstab, "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n")
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
      "path" => "/mnt/checkmode", "state" => "remounted", "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
  end
end
