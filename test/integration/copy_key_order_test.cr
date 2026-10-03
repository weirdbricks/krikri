require "../minitest_helper"
require "file_utils"

# Real ansible-core 2.19.11's registered copy result key orders -
# live-verified via `{{ r | to_json }}` on registered copy: tasks (the
# -v dump sorts alphabetically, so the order is only observable
# programmatically). Real's changed-path result runs diff, dest, src,
# md5sum, checksum, changed (, backup_file), then the add_path_info
# stat block and failed: false; the equal-content and check-mode
# would-not-change paths dispatch real's FILE module instead, whose
# result runs diff, path, changed, the stat block, then the
# action-injected checksum and dest. krikri's wire result omits src/
# md5sum (no staged-tempfile path to echo) and failed: false, and its
# execute() wrapper always materializes a `diff` key (empty list when
# no diff data - real's own always-present-diff shape), so the pins
# below cover the keys krikri emits, in real's relative order.
describe "copy plugin result key order" do
  it "serializes a content-copy success in real copy's key order" do
    dest = PluginSpecHelper.tmp_path("copy-order-content.txt")

    result = PluginSpecHelper.run("copy", {"content" => "key order\n", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "diff", "dest", "md5sum", "checksum", "changed",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes a content-copy with backup: so backup_file follows changed" do
    dest = PluginSpecHelper.tmp_path("copy-order-backup.txt")
    File.write(dest, "original\n")

    result = PluginSpecHelper.run("copy", {"content" => "backup\n", "dest" => dest, "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "diff", "dest", "md5sum", "checksum", "changed", "backup_file",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm(Dir.glob("#{dest}*")) if dest
  end

  it "serializes the equal-content rerun in real copy's file-module key order (path leads, checksum/dest trail)" do
    dest = PluginSpecHelper.tmp_path("copy-order-equal.txt")
    PluginSpecHelper.run("copy", {"content" => "same\n", "dest" => dest})
    result = PluginSpecHelper.run("copy", {"content" => "same\n", "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "diff", "path", "changed", "uid", "gid", "owner", "group", "mode", "state", "size",
      "checksum", "dest",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes a src-copy success in real copy's key order" do
    src = PluginSpecHelper.tmp_path("copy-order-src.txt")
    File.write(src, "src bytes\n")
    dest = PluginSpecHelper.tmp_path("copy-order-src-dest.txt")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "diff", "dest", "checksum", "changed",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes the equal-content src rerun in real copy's file-module key order" do
    src = PluginSpecHelper.tmp_path("copy-order-src2.txt")
    File.write(src, "identical\n")
    dest = PluginSpecHelper.tmp_path("copy-order-src2-dest.txt")
    PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})
    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "diff", "path", "changed", "uid", "gid", "owner", "group", "mode", "state", "size", "dest",
    ])
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes the force-false existing-dest no-op with dest leading (krikri's always-present diff trails)" do
    dest = PluginSpecHelper.tmp_path("copy-order-forcefalse.txt")
    PluginSpecHelper.run("copy", {"content" => "kept\n", "dest" => dest})
    result = PluginSpecHelper.run("copy", {"content" => "other\n", "dest" => dest, "force" => "false"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["dest", "changed", "diff"])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes a check-mode would-change result with diff leading when diff mode is on" do
    dest = PluginSpecHelper.tmp_path("copy-order-check.txt")

    result = PluginSpecHelper.run("copy", {"content" => "check\n", "dest" => dest, "_ansible_check_mode" => "true", "_ansible_diff" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
    # krikri's check-mode content copy also echoes real's censored
    # invocation dict (live-verified at -vvv); it trails the listed keys.
    result.as_h.keys.must_equal(["diff", "changed", "invocation"])
  end

  it "serializes a check-mode would-change result without diff mode (empty-list diff still leads)" do
    dest = PluginSpecHelper.tmp_path("copy-order-check-nodiff.txt")

    result = PluginSpecHelper.run("copy", {"content" => "check\n", "dest" => dest, "_ansible_check_mode" => "true"})

    result.as_h.keys.must_equal(["diff", "changed", "invocation"])
  end

  it "serializes a directory-copy success with dest leading changed" do
    src = PluginSpecHelper.tmp_path("copy-order-dirsrc")
    Dir.mkdir_p(src)
    File.write(File.join(src, "a.txt"), "a")
    dest = PluginSpecHelper.tmp_path("copy-order-dirdst")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    # Real's directory-copy result is bare {dest, src, changed} - no
    # stat block, no msg. krikri's extra msg/stat keys trail real's
    # keys (msg last, after the stat block).
    result.as_h.keys.must_equal([
      "diff", "dest", "changed", "uid", "gid", "owner", "group", "mode", "state", "size", "msg",
    ])
  ensure
    FileUtils.rm_rf(src) if src && Dir.exists?(src)
    FileUtils.rm_rf(dest) if dest && Dir.exists?(dest)
  end
end
