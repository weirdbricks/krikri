require "../minitest_helper"
require "file_utils"

# Real ansible-core 2.19.11's registered blockinfile result key order -
# live-verified via `{{ r | to_json }}` on registered blockinfile:
# tasks: changed, msg, diff, then backup_file only when a backup was
# actually taken, then failed - identical on create, change, remove and
# already-correct runs, and in check mode. Real's wire result ALWAYS
# carries the diff key (a two-entry content/attributes list whose
# before/after bodies are empty outside --diff mode), so the pins below
# expect it on every success. failed: false is backfilled by the
# executor after the plugin JSON, so the plugin-level pins omit it.
describe "blockinfile plugin result key order" do
  it "serializes a create success as changed-msg-diff" do
    path = PluginSpecHelper.tmp_path("blockinfile-order-create.txt")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "hello", "create" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("File created")
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes an already-correct rerun as changed-msg-diff with an empty msg" do
    path = PluginSpecHelper.tmp_path("blockinfile-order-equal.txt")
    params = {"path" => path, "block" => "hello", "create" => "true"}
    PluginSpecHelper.run("blockinfile", params)
    result = PluginSpecHelper.run("blockinfile", params)

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("")
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a backup-taking change with backup_file after diff" do
    path = PluginSpecHelper.tmp_path("blockinfile-order-backup.txt")
    File.write(path, "original\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "new\n", "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "msg", "diff", "backup_file"])
  ensure
    FileUtils.rm(Dir.glob("#{path}*")) if path
  end

  it "serializes a state=absent removal as changed-msg-diff" do
    path = PluginSpecHelper.tmp_path("blockinfile-order-absent.txt")
    File.write(path, "marker\n# BEGIN ANSIBLE MANAGED BLOCK\nblock\n# END ANSIBLE MANAGED BLOCK\nmarker\n")

    result = PluginSpecHelper.run("blockinfile", {"path" => path, "block" => "block", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Block removed")
    result.as_h.keys.must_equal(["changed", "msg", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
