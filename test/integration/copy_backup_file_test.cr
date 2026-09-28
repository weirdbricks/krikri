require "../minitest_helper"
require "file_utils"

# The classic suite pre-created a shared spec/tmp/copy_backup_file in
# before_suite; the minitest suite gives every test its own tmp_path
# subtree instead.

# Regression (found via the testing/podman-diff harness, copy_edge_cases
# case P3b): with backup: true and an overwrite, real Ansible's copy
# module exits with `backup_file` set to the created backup's path (the
# backup file itself was always created on disk here, but the result
# dict never carried the key, so `register:`ed results diverged).
describe "copy plugin backup_file reporting" do
  it "reports backup_file under the result when a content copy overwrites with backup: yes" do
    path = PluginSpecHelper.tmp_path("content-overwrite.txt")
    File.write(path, "v1\n")

    result = PluginSpecHelper.run("copy", {"content" => "v2\n", "dest" => path, "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    backup_file = result["backup_file"].as_s
    backup_file.wont_be_empty
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("v1\n")
    File.read(path).must_equal("v2\n")
  end

  it "reports backup_file when a src-file copy overwrites with backup: yes" do
    src = PluginSpecHelper.tmp_path("src.txt")
    dest = PluginSpecHelper.tmp_path("dest.txt")
    File.write(src, "new\n")
    File.write(dest, "old\n")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    backup_file = result["backup_file"].as_s
    backup_file.wont_be_empty
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("old\n")
  end

  it "omits backup_file when no backup was made" do
    path = PluginSpecHelper.tmp_path("no-backup.txt")

    result = PluginSpecHelper.run("copy", {"content" => "fresh\n", "dest" => path, "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["backup_file"]?.must_be_nil
  end
end
