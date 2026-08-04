require "../spec_helper"
require "file_utils"

private LOCAL_VARS = {"ansible_connection" => "local"}

describe "fetch plugin" do
  it "requires src and dest" do
    result = PluginSpecHelper.run("fetch", {"dest" => "/tmp/whatever"}, LOCAL_VARS)
    result["failed"].as_bool.should be_true

    result = PluginSpecHelper.run("fetch", {"src" => "/etc/hostname"}, LOCAL_VARS)
    result["failed"].as_bool.should be_true
  end

  it "fetches into the default hostname/path layout and is idempotent on rerun" do
    src = File.tempname("fetch-spec-src")
    File.write(src, "fetch me\n")
    dest_root = File.tempname("fetch-spec-dest")
    Dir.mkdir_p(dest_root)

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => "#{dest_root}/"}, LOCAL_VARS)
    result["changed"].as_bool.should be_true
    expected_path = File.join(dest_root, "localhost", src)
    File.read(expected_path).should eq("fetch me\n")

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => "#{dest_root}/"}, LOCAL_VARS)
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq("file already present")
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_root) if dest_root
  end

  it "writes to dest/<basename> when flat: true and dest ends with a separator" do
    src = File.tempname("fetch-spec-src")
    File.write(src, "x")
    dest_dir = File.tempname("fetch-spec-flat")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => "#{dest_dir}/", "flat" => "true"}, LOCAL_VARS)
    result["changed"].as_bool.should be_true
    File.exists?(File.join(dest_dir, File.basename(src))).should be_true
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "writes to the literal dest path when flat: true and dest doesn't end with a separator" do
    src = File.tempname("fetch-spec-src")
    File.write(src, "x")
    dest = File.tempname("fetch-spec-literal")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"}, LOCAL_VARS)
    result["changed"].as_bool.should be_true
    result["dest"].as_s.should eq(dest)
    File.exists?(dest).should be_true
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails when the source is missing and fail_on_missing defaults to true" do
    result = PluginSpecHelper.run("fetch", {"src" => "/nonexistent/fetch-spec-src", "dest" => "/tmp/"}, LOCAL_VARS)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("the remote file does not exist, not transferring, ignored")
  end

  it "does not fail when the source is missing and fail_on_missing is false" do
    result = PluginSpecHelper.run("fetch", {"src" => "/nonexistent/fetch-spec-src", "dest" => "/tmp/", "fail_on_missing" => "false"}, LOCAL_VARS)
    result["failed"].as_bool.should be_false
  end

  it "is skipped under check_mode" do
    result = PluginSpecHelper.run("fetch", {"src" => "/etc/hostname", "dest" => "/tmp/", "check_mode" => "true"}, LOCAL_VARS)
    result["failed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
    result["msg"].as_s.should eq("check mode not (yet) supported for this module")
  end

  it "fails clearly when src is a directory" do
    src_dir = File.tempname("fetch-spec-dir")
    Dir.mkdir_p(src_dir)

    result = PluginSpecHelper.run("fetch", {"src" => src_dir, "dest" => "/tmp/"}, LOCAL_VARS)
    result["failed"].as_bool.should be_true
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
