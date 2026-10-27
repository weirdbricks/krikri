require "../minitest_helper"
require "file_utils"

# `file: state=link` with `follow:` at its default (true) over a link
# whose target is missing: real file.py (ensure_symlink) skips
# set_fs_attributes_if_different and calls module.warn("Cannot set fs
# attributes on a non-existent symlink target. follow should be set to
# False to avoid this.") on every non-check-mode run - a freshly created
# dangling link and an already-correct one alike - because applying
# owner:/group: there chowns THROUGH the link and dies on ENOENT.
# Verified against ansible-playbook 2.19.
describe "file state=link dangling follow (file_link_dangling_follow_test.cr)" do
  it "warns on a newly created dangling link with default follow" do
    dir = PluginSpecHelper.tmp_path("link-dangling", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "link.lnk")

    result = PluginSpecHelper.run("file", {
      "src"   => "missing-target.bin",
      "dest"  => dest,
      "state" => "link",
      "force" => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.symlink?(dest).must_equal(true)
    result["warnings"].as_a.map(&.as_s).must_equal([
      "Cannot set fs attributes on a non-existent symlink target. follow should be set to False to avoid this.",
    ])
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "does not warn when follow is false" do
    dir = PluginSpecHelper.tmp_path("link-dangling-nofollow", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "link.lnk")

    result = PluginSpecHelper.run("file", {
      "src"    => "missing-target.bin",
      "dest"   => dest,
      "state"  => "link",
      "force"  => "true",
      "follow" => "false",
    })

    result["failed"]?.must_be_nil
    result["warnings"]?.must_be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "does not warn when the link target exists" do
    dir = PluginSpecHelper.tmp_path("link-dangling-target-exists", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "link.lnk")
    File.write(File.join(dir, "target.bin"), "payload")

    result = PluginSpecHelper.run("file", {
      "src"   => "target.bin",
      "dest"  => dest,
      "state" => "link",
    })

    result["failed"]?.must_be_nil
    result["warnings"]?.must_be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "does not fail a dangling link task that sets owner" do
    dir = PluginSpecHelper.tmp_path("link-dangling-owner", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "link.lnk")

    result = PluginSpecHelper.run("file", {
      "src"   => "missing-target.bin",
      "dest"  => dest,
      "state" => "link",
      "force" => "true",
      "owner" => LibC.getuid.to_s,
    })

    result["failed"]?.must_be_nil
    File.symlink?(dest).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "does not warn in check mode on a dangling link" do
    dir = PluginSpecHelper.tmp_path("link-dangling-check", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)

    result = PluginSpecHelper.run("file", {
      "src"                 => "missing-target.bin",
      "dest"                => File.join(dir, "link.lnk"),
      "state"               => "link",
      "force"               => "true",
      "_ansible_check_mode" => "true",
    })

    result["warnings"]?.must_be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
