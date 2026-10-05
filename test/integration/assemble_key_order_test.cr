require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's registered assemble result key order -
# live-verified via `{{ r | to_json }}` on registered assemble: tasks:
# src, dest, checksum, md5sum, then backup_file only when a backup was
# taken, then changed, msg, the stat block, failed - IDENTICAL on
# changed and unchanged runs (the checksums ride the no-op result
# too), and no diff key outside --diff mode. failed: false is
# backfilled by the executor after the plugin JSON, so the plugin-level
# pins omit it.
describe "assemble plugin result key order" do
  it "serializes a fresh assemble success as src-dest-checksum-md5sum-changed-msg plus the stat block" do
    src = PluginSpecHelper.tmp_path("assemble-order-src")
    Dir.mkdir_p(src)
    File.write(File.join(src, "1.conf"), "part one\n")
    dest = PluginSpecHelper.tmp_path("assemble-order-dest.conf")

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    result["src"].as_s.must_equal(src)
    result["msg"].as_s.must_equal("OK")
    result.as_h.keys.must_equal([
      "src", "dest", "checksum", "md5sum", "changed", "msg",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_rf(src) if src && Dir.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "serializes an already-correct rerun in the same order (checksums still ride along)" do
    src = PluginSpecHelper.tmp_path("assemble-order-src2")
    Dir.mkdir_p(src)
    File.write(File.join(src, "1.conf"), "part one\n")
    dest = PluginSpecHelper.tmp_path("assemble-order-dest2.conf")
    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})
    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "src", "dest", "checksum", "md5sum", "changed", "msg",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm_rf(src) if src && Dir.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
