require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "copy_backup_file")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

# Regression (found via the testing/podman-diff harness, copy_edge_cases
# case P3b): with backup: true and an overwrite, real Ansible's copy
# module exits with `backup_file` set to the created backup's path (the
# backup file itself was always created on disk here, but the result
# dict never carried the key, so `register:`ed results diverged).
describe "copy plugin backup_file reporting" do
  it "reports backup_file under the result when a content copy overwrites with backup: yes" do
    path = File.join(TMP_DIR, "content-overwrite.txt")
    File.write(path, "v1\n")

    result = PluginSpecHelper.run("copy", {"content" => "v2\n", "dest" => path, "backup" => "true"})

    result["changed"].as_bool.should be_true
    backup_file = result["backup_file"].as_s
    backup_file.should_not be_empty
    File.exists?(backup_file).should be_true
    File.read(backup_file).should eq("v1\n")
    File.read(path).should eq("v2\n")
  end

  it "reports backup_file when a src-file copy overwrites with backup: yes" do
    src = File.join(TMP_DIR, "src.txt")
    dest = File.join(TMP_DIR, "dest.txt")
    File.write(src, "new\n")
    File.write(dest, "old\n")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "backup" => "true"})

    result["changed"].as_bool.should be_true
    backup_file = result["backup_file"].as_s
    backup_file.should_not be_empty
    File.exists?(backup_file).should be_true
    File.read(backup_file).should eq("old\n")
  end

  it "omits backup_file when no backup was made" do
    path = File.join(TMP_DIR, "no-backup.txt")

    result = PluginSpecHelper.run("copy", {"content" => "fresh\n", "dest" => path, "backup" => "true"})

    result["changed"].as_bool.should be_true
    result["backup_file"]?.should be_nil
  end
end
