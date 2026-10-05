require "../minitest_helper"
require "file_utils"

# Round 993003 (kop_storage, cold recap): a state=mounted task whose mount
# command fails must NOT leave its fstab entry behind. Real mount.py restores
# the pre-edit fstab (write_fstab with the backup lines) and rmdirs the
# mountpoint dirs it created when the mount fails - "A non-working fstab entry
# may break the system at the reboot, so undo all the changes if possible"
# (ansible/ansible#59183). Krikri previously kept the entry, so the role's
# later state=absent cleanup loop item (/var/tmp/kop_mntfail) reported changed
# on krikri but ok on real (real changed=14 vs krikri changed=15).
#
# The mount command itself is shimmed via a restricted child PATH, so these
# stay root-free and deterministic: a failing shim exercises the restore, a
# succeeding one pins that the entry survives a successful mount.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)

private def write_mount_shim(dir : String, exit_code : Int32) : String
  bin_dir = File.join(dir, "bin")
  FileUtils.mkdir_p(bin_dir)
  shim = File.join(bin_dir, "mount")
  File.write(shim, <<-SH)
    #!/bin/sh
    if [ "#{exit_code}" != "0" ]; then
      echo "mount: $*: special device /var/tmp/kop_nosuch_source does not exist." >&2
    fi
    exit #{exit_code}
    SH
  File.chmod(shim, 0o755)
  bin_dir
end

private def mount_shim_env(bin_dir : String) : Hash(String, String)
  {"PATH" => "#{bin_dir}:#{ENV["PATH"]? || ""}"}
end

describe "mount plugin - failed mount restores fstab (round 993003)" do
  it "removes the fstab entry and the created mountpoint after a failed mount" do
    tmp = PluginSpecHelper.tmp_path("mount-restore-fail")
    FileUtils.mkdir_p(tmp)
    fstab = File.join(tmp, "fstab")
    File.write(fstab, "# krikri mount restore test\n")
    path = File.join(tmp, "kop_mntfail")

    result = PluginSpecHelper.run("mount", {
      "path"   => path,
      "src"    => "/var/tmp/kop_nosuch_source",
      "fstype" => "ext4",
      "state"  => "mounted",
      "fstab"  => fstab,
    }, env: mount_shim_env(write_mount_shim(tmp, 1)))

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.starts_with?("Error mounting #{path}:").must_equal(true)

    # The pre-edit fstab content is restored byte-for-byte, and the
    # mountpoint dir the failed attempt created is gone again - so a
    # later state=absent finds nothing to do (Ansible's ok).
    File.read(fstab).must_equal("# krikri mount restore test\n")
    File.exists?(path).must_equal(false)
  end

  it "keeps a pre-existing mountpoint dir after a failed mount" do
    tmp = PluginSpecHelper.tmp_path("mount-restore-existing-dir")
    FileUtils.mkdir_p(tmp)
    fstab = File.join(tmp, "fstab")
    File.write(fstab, "")
    path = File.join(tmp, "kop_mntfail")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "keepme"), "x")

    PluginSpecHelper.run("mount", {
      "path"   => path,
      "src"    => "/var/tmp/kop_nosuch_source",
      "fstype" => "ext4",
      "state"  => "mounted",
      "fstab"  => fstab,
    }, env: mount_shim_env(write_mount_shim(tmp, 1)))

    # Ansible's undo rmdir only removes the dirs it created; a mountpoint
    # that already existed (here: non-empty, so even an rmdir would fail)
    # survives the failed mount.
    File.exists?(File.join(path, "keepme")).must_equal(true)
  end

  it "keeps the fstab entry when the mount succeeds" do
    tmp = PluginSpecHelper.tmp_path("mount-restore-success")
    FileUtils.mkdir_p(tmp)
    fstab = File.join(tmp, "fstab")
    File.write(fstab, "# krikri mount restore test\n")
    path = File.join(tmp, "kop_mnt")

    result = PluginSpecHelper.run("mount", {
      "path"   => path,
      "src"    => "tmpfs",
      "fstype" => "tmpfs",
      "opts"   => "size=16m",
      "state"  => "mounted",
      "fstab"  => fstab,
    }, env: mount_shim_env(write_mount_shim(tmp, 0)))

    result["changed"].as_bool.must_equal(true)
    result["failed"]?.must_be_nil
    File.read(fstab).must_equal("# krikri mount restore test\ntmpfs #{path} tmpfs size=16m 0 0\n")
  end
end
