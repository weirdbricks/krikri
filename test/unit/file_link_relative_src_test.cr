require "../minitest_helper"
require "file_utils"

# `file: state=link` with a RELATIVE src must check the src's existence
# against the DEST's directory (a symlink's relative target resolves
# against the link's own directory - real file.py joins
# `absrc = os.path.join(relpath, src)` before its os.path.exists), not
# the module process's cwd. The old cwd-relative check failed
# baztian.joplin's `src: Joplin-<v>.AppImage` + `dest: /opt/Joplin.
# AppImage` with "src file does not exist" on a file that DID exist
# next to the dest (round 5250000). Verified against ansible-playbook
# 2.19.11 before being encoded here.
describe "file state=link relative src (file_link_relative_src_test.cr)" do
  it "creates a link whose relative src exists next to the dest" do
    dir = PluginSpecHelper.tmp_path("link-rel-src", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "Joplin-3.7.21.AppImage")
    File.write(target, "payload")

    result = PluginSpecHelper.run("file", {
      "src"   => "Joplin-3.7.21.AppImage",
      "dest"  => File.join(dir, "Joplin.AppImage"),
      "state" => "link",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.symlink?(File.join(dir, "Joplin.AppImage")).must_equal(true)
    File.readlink(File.join(dir, "Joplin.AppImage")).must_equal("Joplin-3.7.21.AppImage")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "still fails with the dest-relative path in the message when the src is missing" do
    dir = PluginSpecHelper.tmp_path("link-rel-src-missing", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)

    result = PluginSpecHelper.run("file", {
      "src"   => "missing-target.bin",
      "dest"  => File.join(dir, "link.lnk"),
      "state" => "link",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "src file does not exist, use \"force=yes\" if you really want to create the link: #{File.join(dir, "missing-target.bin")}"
    )
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "keeps absolute srcs checking against themselves" do
    dir = PluginSpecHelper.tmp_path("link-abs-src", Random::Secure.hex(4))
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "target.txt")
    File.write(target, "payload")

    result = PluginSpecHelper.run("file", {
      "src"   => target,
      "dest"  => File.join(dir, "link.lnk"),
      "state" => "link",
    })

    result["failed"]?.must_be_nil
    File.symlink?(File.join(dir, "link.lnk")).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
