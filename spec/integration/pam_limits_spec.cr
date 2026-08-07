require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "pam_limits")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def dest_path(name : String = "limits.d") : String
  File.join(TMP_DIR, name)
end

describe "pam_limits plugin" do
  it "appends an entry to a new file" do
    dest = dest_path("new.conf")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "core", "value" => "0",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should contain("*\thard\tcore\t0")
  end

  it "is idempotent on an exact rerun" do
    dest = dest_path("idem.conf")
    params = {"dest" => dest, "domain" => "*", "limit_type" => "hard",
              "limit_item" => "core", "value" => "0"}
    PluginSpecHelper.run("pam_limits", params)

    result = PluginSpecHelper.run("pam_limits", params)

    result["changed"].as_bool.should be_false
  end

  it "updates an existing entry with a different value" do
    dest = dest_path("update.conf")
    File.write(dest, "*\thard\tcore\t1\n")

    result = PluginSpecHelper.run("pam_limits", {
      "dest" => dest, "domain" => "*", "limit_type" => "hard",
      "limit_item" => "core", "value" => "0",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should contain("*\thard\tcore\t0")
  end

  it "fails when required params are missing" do
    result = PluginSpecHelper.run("pam_limits", {"domain" => "*"})
    result["failed"].as_bool.should be_true
  end
end
