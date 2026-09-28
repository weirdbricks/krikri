require "../minitest_helper"

private KEY1 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX"
private KEY2 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentKeyDataYYYYYYYYYYYYYYYYYY"

describe "known_hosts plugin" do
  it "adds a new entry and reports changed" do
    path = PluginSpecHelper.tmp_path("known_hosts_add")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"]?.must_be_nil("real known_hosts returns no msg on success")
    File.read(path).must_include("example.com")
  end

  it "is idempotent when the same key is already present" do
    path = PluginSpecHelper.tmp_path("known_hosts_idempotent")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil("real known_hosts returns no msg on success")
  end

  it "replaces a differing key for the same host" do
    path = PluginSpecHelper.tmp_path("known_hosts_replace")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY2, "path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"]?.must_be_nil("real known_hosts returns no msg on success")
    content = File.read(path)
    content.must_include("DifferentKeyData")
    content.wont_include("ExampleKeyData")
  end

  it "removes an entry when state: absent" do
    path = PluginSpecHelper.tmp_path("known_hosts_remove")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "state" => "absent", "path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"]?.must_be_nil("real known_hosts returns no msg on success")
    File.read(path).wont_include("example.com")
  end

  it "is a no-op removing an entry that isn't present" do
    path = PluginSpecHelper.tmp_path("known_hosts_remove_absent")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "state" => "absent", "path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil("real known_hosts returns no msg on success")
  end

  it "fails when state: present is given without a key" do
    path = PluginSpecHelper.tmp_path("known_hosts_missing_key")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "path" => path})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("No key specified when adding a host")
  end

  it "fails when the parent directory of path does not exist" do
    path = File.join(PluginSpecHelper.tmp_path("no-such-dir"), "known_hosts_parent_missing")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("known_hosts", {"name" => "example.com", "key" => KEY1, "path" => path})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    File.exists?(File.dirname(path)).must_equal(false)
  end
end
