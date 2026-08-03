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

  it "does not actually write the fstab file in check mode (regression: check_mode only guarded the mount/umount step, not the fstab write)" do
    fstab = fresh_fstab("write-check.fstab", "UUID=abc / ext4 errors=remount-ro 0 1\n")

    result = PluginSpecHelper.run("mount", {
      "path" => "/mnt/checkmode", "src" => "/dev/fake", "fstype" => "ext4", "state" => "present", "fstab" => fstab, "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(fstab).should eq("UUID=abc / ext4 errors=remount-ro 0 1\n")
  end
end
