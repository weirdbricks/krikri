require "../minitest_helper"
require "file_utils"

# Real ansible-core 2.19.11's registered ini_file result key order -
# live-verified via `{{ r | to_json }}` on registered ini_file: tasks:
# changed, diff, msg, path, then backup_file only when a backup was
# taken, then the add_path_info stat block, failed - identical on
# create, change, remove and no-op runs. failed: false is backfilled by
# the executor after the plugin JSON, so the plugin-level pins omit it.
describe "ini_file plugin result key order" do
  it "serializes a create success as changed-diff-msg-path plus the stat block" do
    path = PluginSpecHelper.tmp_path("ini-order-create.ini")

    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val1"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("section and option added")
    result.as_h.keys.must_equal([
      "changed", "diff", "msg", "path",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes an already-correct rerun in the same order with msg OK" do
    path = PluginSpecHelper.tmp_path("ini-order-equal.ini")
    params = {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val1"}
    PluginSpecHelper.run("ini_file", params)
    result = PluginSpecHelper.run("ini_file", params)

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("OK")
    result.as_h.keys.must_equal([
      "changed", "diff", "msg", "path",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a value change in the same order" do
    path = PluginSpecHelper.tmp_path("ini-order-change.ini")
    PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val1"})
    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val2"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("option changed")
    result.as_h.keys.must_equal([
      "changed", "diff", "msg", "path",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a backup-taking change with backup_file after path" do
    path = PluginSpecHelper.tmp_path("ini-order-backup.ini")
    PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val1"})
    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val2", "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "changed", "diff", "msg", "path", "backup_file",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    FileUtils.rm(Dir.glob("#{path}*")) if path
  end

  it "serializes a state=absent removal in the same order" do
    path = PluginSpecHelper.tmp_path("ini-order-absent.ini")
    PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "value" => "val1"})
    result = PluginSpecHelper.run("ini_file", {"path" => path, "section" => "sec1", "option" => "opt1", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "changed", "diff", "msg", "path",
      "uid", "gid", "owner", "group", "mode", "state", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
