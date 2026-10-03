require "../minitest_helper"
require "file_utils"

# Real ansible-core 2.19.11's registered replace result key order -
# live-verified via `{{ r | to_json }}` on registered replace: tasks:
# rc leads, then backup_file only when a backup was taken, then msg
# (empty string included on a no-matches run), then changed, failed -
# identical on changed, unchanged, no-match and check-mode runs.
# failed: false is backfilled by the executor after the plugin JSON, so
# the plugin-level pins omit it.
describe "replace plugin result key order" do
  it "serializes a replacement success with rc leading" do
    path = PluginSpecHelper.tmp_path("replace-order-change.txt")
    File.write(path, "old text here\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "old", "replace" => "new"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("1 replacements made")
    result.as_h.keys.must_equal(["rc", "msg", "changed"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes an already-correct rerun with an empty msg in the same order" do
    path = PluginSpecHelper.tmp_path("replace-order-equal.txt")
    File.write(path, "new text here\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "old", "replace" => "new"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("")
    result.as_h.keys.must_equal(["rc", "msg", "changed"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a backup-taking change with backup_file right after rc" do
    path = PluginSpecHelper.tmp_path("replace-order-backup.txt")
    File.write(path, "old text here\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "old", "replace" => "new", "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["rc", "backup_file", "msg", "changed"])
  ensure
    FileUtils.rm(Dir.glob("#{path}*")) if path
  end

  it "serializes the before/after no-match exit with rc leading" do
    path = PluginSpecHelper.tmp_path("replace-order-nomatch.txt")
    File.write(path, "body\n")

    result = PluginSpecHelper.run("replace", {
      "path" => path, "regexp" => "^body$", "replace" => "body", "after" => "no-such-line", "before" => "no-such-either",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["rc", "msg", "changed"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
