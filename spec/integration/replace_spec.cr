require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "replace")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def fresh_file(name : String, content : String) : String
  path = File.join(TMP_DIR, name)
  File.write(path, content)
  path
end

describe "replace plugin" do
  it "replaces a regex match in the file" do
    path = fresh_file("one.conf", "  gpgcheck = 0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("gpgcheck=1\n")
  end

  it "reports changed: false on an idempotent rerun" do
    path = fresh_file("idem.conf", "gpgcheck=1\n")
    params = {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"}
    PluginSpecHelper.run("replace", params)

    result = PluginSpecHelper.run("replace", params)

    result["changed"].as_bool.should be_false
  end

  it "applies mode when given" do
    path = fresh_file("mode.conf", "x=1\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^x", "replace" => "y", "mode" => "0600"})

    result["changed"].as_bool.should be_true
    (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o600)
  end

  it "fails when the file doesn't exist" do
    result = PluginSpecHelper.run("replace", {"path" => File.join(TMP_DIR, "nope.txt"), "regexp" => "x", "replace" => "y"})

    result["failed"].as_bool.should be_true
  end

  it "fails when regexp is missing" do
    path = fresh_file("noregexp.txt", "x")
    result = PluginSpecHelper.run("replace", {"path" => path})

    result["failed"].as_bool.should be_true
  end
end
