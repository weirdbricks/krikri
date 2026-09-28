require "../minitest_helper"
require "file_utils"

private LOCAL_VARS = {"ansible_connection" => "local"}

describe "fetch plugin" do
  it "requires src and dest" do
    result = PluginSpecHelper.run("fetch", {"dest" => "/tmp/whatever"}, LOCAL_VARS)
    result["failed"].as_bool.must_equal(true)

    result = PluginSpecHelper.run("fetch", {"src" => "/etc/hostname"}, LOCAL_VARS)
    result["failed"].as_bool.must_equal(true)
  end

  it "fetches into the default hostname/path layout and is idempotent on rerun" do
    src = File.tempname("fetch-spec-src")
    File.write(src, "fetch me\n")
    dest_root = File.tempname("fetch-spec-dest")
    Dir.mkdir_p(dest_root)

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => "#{dest_root}/"}, LOCAL_VARS)
    result["changed"].as_bool.must_equal(true)
    expected_path = File.join(dest_root, "localhost", src)
    File.read(expected_path).must_equal("fetch me\n")

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => "#{dest_root}/"}, LOCAL_VARS)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("file already present")
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
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(dest_dir, File.basename(src))).must_equal(true)
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
    result["changed"].as_bool.must_equal(true)
    result["dest"].as_s.must_equal(dest)
    File.exists?(dest).must_equal(true)
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails when the source is missing and fail_on_missing defaults to true" do
    result = PluginSpecHelper.run("fetch", {"src" => "/nonexistent/fetch-spec-src", "dest" => "/tmp/"}, LOCAL_VARS)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the remote file does not exist, not transferring, ignored")
  end

  it "does not fail when the source is missing and fail_on_missing is false" do
    result = PluginSpecHelper.run("fetch", {"src" => "/nonexistent/fetch-spec-src", "dest" => "/tmp/", "fail_on_missing" => "false"}, LOCAL_VARS)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "is skipped under check_mode" do
    result = PluginSpecHelper.run("fetch", {"src" => "/etc/hostname", "dest" => "/tmp/", "_ansible_check_mode" => "true"}, LOCAL_VARS)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("check mode not (yet) supported for this module")
  end

  it "fails clearly when src is a directory" do
    src_dir = File.tempname("fetch-spec-dir")
    Dir.mkdir_p(src_dir)

    result = PluginSpecHelper.run("fetch", {"src" => src_dir, "dest" => "/tmp/"}, LOCAL_VARS)
    result["failed"].as_bool.must_equal(true)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "rejects a hostname containing path separators instead of escaping dest (flat: false)" do
    src = File.tempname("fetch-spec-src")
    File.write(src, "x")
    dest_root = File.tempname("fetch-spec-escape")
    Dir.mkdir_p(dest_root)

    result = PluginSpecHelper.run(
      "fetch",
      {"src" => src, "dest" => "#{dest_root}/"},
      LOCAL_VARS,
      host_name: "localhost/../../etc",
    )
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("cannot be used as a fetch destination directory")
    Dir.exists?(File.join(dest_root, "localhost")).must_equal(false)
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_root) if dest_root
  end

  it "rejects a src whose '..' components escape dest (flat: false) with real fetch's traversal message" do
    dest_root = File.tempname("fetch-spec-dest")
    Dir.mkdir_p(dest_root)

    result = PluginSpecHelper.run(
      "fetch",
      {"src" => "/../../etc/passwd", "dest" => dest_root},
      LOCAL_VARS,
    )
    result["failed"].as_bool.must_equal(true)
    falsey?(result["changed"]?.try(&.as_bool)).must_equal(true)
    result["msg"].as_s.must_equal(
      "Detected directory traversal, expected to be contained in '#{dest_root}' but got '#{dest_root}/localhost/../../etc/passwd'")
    File.exists?(File.join(File.dirname(dest_root), "etc", "passwd")).must_equal(false)
  ensure
    FileUtils.rm_rf(dest_root) if dest_root
  end

  it "allows a src with '..' components that stay inside dest and writes the normalized path (flat: false)" do
    src_name = "fetch-spec-src-#{Random.new.hex(4)}"
    dest_root = File.tempname("fetch-spec-dest")
    Dir.mkdir_p(File.join(dest_root, "localhost"))
    src = File.join(dest_root, "localhost", src_name)
    File.write(src, "x")
    src_param = "#{dest_root}/localhost/../localhost/#{src_name}"

    result = PluginSpecHelper.run(
      "fetch",
      {"src" => src_param, "dest" => dest_root},
      LOCAL_VARS,
    )
    result["changed"].as_bool.must_equal(true)
    result["dest"].as_s.must_equal(File.expand_path(File.join(dest_root, "localhost", src_param)))
    File.read(File.expand_path(File.join(dest_root, "localhost", src_param))).must_equal("x")
  ensure
    FileUtils.rm_rf(dest_root) if dest_root
  end
end
