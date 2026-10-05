require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's registered lineinfile result key orders -
# live-verified via `{{ r | to_json }}` on registered lineinfile: tasks.
# state=present runs changed, msg, backup, diff, failed - backup: ""
# even when no backup was taken and msg: "" on an already-correct
# re-run; state=absent leads with a `found` count right after changed:
# changed, found, msg, backup, diff, failed. The missing-file
# "file not present" early exit is just changed/msg. failed: false is
# backfilled by the executor after the plugin JSON, so the plugin-level
# pins below omit it.
describe "lineinfile plugin result key order" do
  it "serializes a create success in Ansible's changed-msg-backup-diff order" do
    path = PluginSpecHelper.tmp_path("lineinfile-order-create.txt")

    result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "hello", "create" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "msg", "backup", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes an already-correct rerun with the same order and an empty msg" do
    path = PluginSpecHelper.tmp_path("lineinfile-order-equal.txt")
    params = {"path" => path, "line" => "hello", "create" => "true"}
    PluginSpecHelper.run("lineinfile", params)
    result = PluginSpecHelper.run("lineinfile", params)

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("")
    result.as_h.keys.must_equal(["changed", "msg", "backup", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a state=absent removal with found right after changed" do
    path = PluginSpecHelper.tmp_path("lineinfile-order-absent.txt")
    File.write(path, "hello\n")

    result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "hello", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    result["found"].as_i.must_equal(1)
    result.as_h.keys.must_equal(["changed", "found", "msg", "backup", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a state=absent no-op with found leading msg" do
    path = PluginSpecHelper.tmp_path("lineinfile-order-absent-noop.txt")
    File.write(path, "other\n")

    result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "nope", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "found", "msg", "backup", "diff"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes the missing-file absent early exit as changed-msg only" do
    path = PluginSpecHelper.tmp_path("lineinfile-order-missing.txt")

    result = PluginSpecHelper.run("lineinfile", {"path" => path, "line" => "x", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("file not present")
    result.as_h.keys.must_equal(["changed", "msg"])
  end
end
