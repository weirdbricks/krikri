require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def kh_path(name : String) : String
  File.join(TMP_DIR, name)
end

private KEY1 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX"
private KEY2 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentKeyDataYYYYYYYYYYYYYYYYYY"

describe "known_hosts plugin" do
  it "adds a new entry and reports changed" do
    path = kh_path("known_hosts_add")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"]?.should be_nil, "real known_hosts returns no msg on success"
    File.read(path).should contain("example.com")
  end

  it "is idempotent when the same key is already present" do
    path = kh_path("known_hosts_idempotent")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
    result["msg"]?.should be_nil, "real known_hosts returns no msg on success"
  end

  it "replaces a differing key for the same host" do
    path = kh_path("known_hosts_replace")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY2, "path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"]?.should be_nil, "real known_hosts returns no msg on success"
    content = File.read(path)
    content.should contain("DifferentKeyData")
    content.should_not contain("ExampleKeyData")
  end

  it "removes an entry when state: absent" do
    path = kh_path("known_hosts_remove")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "state" => "absent", "path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"]?.should be_nil, "real known_hosts returns no msg on success"
    File.read(path).should_not contain("example.com")
  end

  it "is a no-op removing an entry that isn't present" do
    path = kh_path("known_hosts_remove_absent")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "state" => "absent", "path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
    result["msg"]?.should be_nil, "real known_hosts returns no msg on success"
  end

  it "fails when state: present is given without a key" do
    path = kh_path("known_hosts_missing_key")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "path" => path})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("No key specified when adding a host")
  end

  it "fails when the parent directory of path does not exist" do
    path = File.join(TMP_DIR, "no-such-dir", "known_hosts_parent_missing")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    File.exists?(File.dirname(path)).should be_false
  end
end
