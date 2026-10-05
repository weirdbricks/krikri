require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's registered tempfile result key order -
# live-verified via `{{ r | to_json }}` on registered tempfile: tasks:
# changed, path, then the add_path_info stat block, failed - identical
# for state file and directory (mode 0600/0700 from mktemp itself), and
# unchanged with explicit path/prefix/suffix. No msg key. failed: false
# is backfilled by the executor after the plugin JSON, so the
# plugin-level pins omit it.
describe "tempfile plugin result key order" do
  it "serializes a state=file success as changed-path plus the stat block" do
    result = PluginSpecHelper.run("tempfile", {} of String => String)

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "changed", "path", "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
    result["state"].as_s.must_equal("file")
    result["mode"].as_s.must_equal("0600")
  ensure
    path = result && result["path"]?.try(&.as_s)
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a state=directory success in the same order with mode 0700" do
    result = PluginSpecHelper.run("tempfile", {"state" => "directory"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "changed", "path", "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
    result["state"].as_s.must_equal("directory")
    result["mode"].as_s.must_equal("0700")
  ensure
    path = result && result["path"]?.try(&.as_s)
    FileUtils.rm_rf(path) if path && Dir.exists?(path)
  end
end
