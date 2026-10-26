require "../minitest_helper"
require "../../src/krikri/plugin_helpers/file_attributes"

describe Krikri::PluginHelpers::FileAttributes do
  describe ".parse_mime" do
    it "parses a real `file --mime-type --mime-encoding` line" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("/etc/hostname: text/plain; charset=us-ascii")
      mimetype.must_equal("text/plain")
      charset.must_equal("us-ascii")
    end

    it "tolerates a colon inside the path itself, using the last colon as the separator" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("/weird:path: application/pdf; charset=binary")
      mimetype.must_equal("application/pdf")
      charset.must_equal("binary")
    end

    it "falls back to unknown/unknown (Ansible's own fallback) on unparseable output" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("")
      mimetype.must_equal("unknown")
      charset.must_equal("unknown")
    end
  end

  describe ".parse_lsattr" do
    it "parses a real `lsattr -vd` line with a version and one flag set" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("719511458  --------------e------- /etc/hostname")
      version.must_equal("719511458")
      attr_flags.must_equal("e")
      attributes.must_equal(["extents"])
    end

    it "returns empty attr_flags/attributes when no flags are set" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("12345  ---------------------- /tmp/x")
      version.must_equal("12345")
      attr_flags.must_equal("")
      attributes.must_equal([] of String)
    end

    it "maps multiple flags to their Ansible attribute names" do
      _, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("1  ----i---------e------- /x")
      attr_flags.must_equal("ie")
      attributes.must_equal(["immutable", "extents"])
    end

    it "falls back to nil/empty/[] (Ansible's own fallback) on unparseable output" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("")
      version.must_be_nil
      attr_flags.must_equal("")
      attributes.must_equal([] of String)
    end
  end
end

# File::Info exposes no uid/gid accessors - read them via the same raw
# stat/lstat the plugin itself uses.
private def file_uid(path : String, follow_symlinks : Bool = true) : UInt32
  s = uninitialized LibC::Stat
  if follow_symlinks
    LibC.stat(path, pointerof(s))
  else
    LibC.lstat(path, pointerof(s))
  end
  s.st_uid
end

private def file_gid(path : String, follow_symlinks : Bool = true) : UInt32
  s = uninitialized LibC::Stat
  if follow_symlinks
    LibC.stat(path, pointerof(s))
  else
    LibC.lstat(path, pointerof(s))
  end
  s.st_gid
end

# A group the running user belongs to beyond its primary one: chgrp to
# it is permitted without root (the POSIX_CHOWN_RESTRICTED rule lets a
# file's owner change its group to one of the process's groups), which
# lets the follow: default be exercised both ways non-root. Owner:,
# unlike group:, can NEVER be chown'd to another user by a non-root
# owner on Linux, so the owner-root case below can only assert the
# failure path.
SUPPLEMENTARY_GROUP = begin
  primary = `id -gn`.strip
  `id -Gn`.split.find { |group| group != primary }
end

# Ansible's file module defaults follow: to true for every state, so
# owner:/group: on a state=link dest are applied to the link's TARGET -
# a chown the running user can't perform there fails the task with the
# bare "chown failed" msg plus the OSError under `exception`, and the
# result's path (and its stat fields) name the resolved target, not the
# link (issue #603).
describe "file plugin follow symlinks default (file_attributes_test.cr)" do
  it "state=link with owner: root follows the link and fails chown on the non-root-owned target" do
    skip "chown to root always succeeds when running as root" if PluginSpecHelper.running_as_root?
    dir = PluginSpecHelper.tmp_path("file-follow-link", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "target.txt")
    File.write(target, "payload")
    target_uid = file_uid(target)

    result = PluginSpecHelper.run("file", {
      "src"   => target,
      "dest"  => File.join(dir, "link.txt"),
      "state" => "link",
      "owner" => "root",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chown failed")
    result["exception"].as_s.must_match(/Operation not permitted/)
    result["path"].as_s.must_equal(File.realpath(target))
    file_uid(target).must_equal(target_uid)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "state=link with follow: false applies group: to the link itself, leaving the target alone" do
    skip "needs a supplementary group distinct from the primary one" unless grp = SUPPLEMENTARY_GROUP
    dir = PluginSpecHelper.tmp_path("file-follow-link-off", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "target.txt")
    File.write(target, "payload")
    target_gid = file_gid(target)

    result = PluginSpecHelper.run("file", {
      "src"    => target,
      "dest"   => File.join(dir, "link.txt"),
      "state"  => "link",
      "group"  => grp,
      "follow" => "false",
    })

    result["failed"]?.must_be_nil
    file_gid(File.join(dir, "link.txt"), follow_symlinks: false).must_equal(`getent group #{grp} | cut -d: -f3`.strip.to_u32)
    file_gid(target).must_equal(target_gid)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "state=link with the default follow applies group: to the target, leaving the link alone" do
    skip "needs a supplementary group distinct from the primary one" unless grp = SUPPLEMENTARY_GROUP
    dir = PluginSpecHelper.tmp_path("file-follow-link-target", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "target.txt")
    File.write(target, "payload")
    target_gid = file_gid(target)

    result = PluginSpecHelper.run("file", {
      "src"   => target,
      "dest"  => File.join(dir, "link.txt"),
      "state" => "link",
      "group" => grp,
    })

    result["failed"]?.must_be_nil
    file_gid(target).must_equal(`getent group #{grp} | cut -d: -f3`.strip.to_u32)
    file_gid(File.join(dir, "link.txt"), follow_symlinks: false).must_equal(target_gid)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
