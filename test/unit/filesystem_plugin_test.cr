require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/filesystem.cr's per-fstype class
# instantiation, pinned against real community.general.filesystem
# (live-verified in Debian podman containers: issue #1856's kpg
# 000018-multi-dpkg_divert-happy check-mode run). Real main() reads
# blkid's TYPE, then instantiates the fstype's class - F2fs.__init__ and
# Btrfs.__init__ resolve their mkfs binary with get_bin_path(required=True)
# there, BEFORE the same-fs/resizefs branches and with no check_mode gate
# (create() is the only check-mode-aware part), so a host without the
# binary fails the task in check mode too. krikri answered `changed`.
describe "filesystem plugin fstype class instantiation" do
  private def existing_device(name : String) : String
    dir = PluginSpecHelper.tmp_path("filesystem-#{name}")
    dev = File.join(dir, "dest.txt")
    FileUtils.mkdir_p(dir)
    File.touch(dev)
    dev
  end

  it "fails a missing mkfs.f2fs in check mode instead of answering changed" do
    skip("mkfs.f2fs is installed here, so real Ansible would not fail at get_bin_path") if Process.find_executable("mkfs.f2fs")

    result = PluginSpecHelper.run("filesystem", {
      "dev"                 => existing_device("f2fs-probe"),
      "fstype"              => "f2fs",
      "state"               => "present",
      "resizefs"            => "true",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.starts_with?(
      %(Failed to find required executable "mkfs.f2fs" in paths: )
    ).must_equal(true, result["msg"].as_s)
  end

  it "reports a missing device before resolving the fstype's mkfs binary" do
    result = PluginSpecHelper.run("filesystem", {
      "dev"    => "/krikri-does-not-exist/dest.txt",
      "fstype" => "f2fs",
      "state"  => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Device /krikri-does-not-exist/dest.txt not found.")
  end

  it "never resolves mkfs for state=absent" do
    result = PluginSpecHelper.run("filesystem", {
      "dev"                 => existing_device("absent-probe"),
      "fstype"              => "f2fs",
      "state"               => "absent",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
  end
end
