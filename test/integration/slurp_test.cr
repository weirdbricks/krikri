require "../minitest_helper"
require "file_utils"
require "base64"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "slurp plugin" do
  it "returns a file's content base64-encoded (real Ansible always does)" do
    path = tmp_path("slurp_armored.txt")
    File.write(path, "hello slurp")

    result = PluginSpecHelper.run("slurp", {"src" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["encoding"].as_s.must_equal("base64")
    Base64.decode_string(result["content"].as_s).must_equal("hello slurp")
    result["source"].as_s.must_equal(path)
  end

  it "rejects the fabricated armor param like real Ansible's argument-spec validation" do
    path = tmp_path("slurp_armor_reject.txt")
    File.write(path, "plain text")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unsupported parameters for (ansible.builtin.slurp) module: armor. Supported parameters include: src (path).")
  end

  it "accepts the path alias for src" do
    path = tmp_path("slurp_alias.txt")
    File.write(path, "aliased")

    result = PluginSpecHelper.run("slurp", {"path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    Base64.decode_string(result["content"].as_s).must_equal("aliased")
  end

  it "fails with real Ansible's missing-argument message when src is absent" do
    result = PluginSpecHelper.run("slurp", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: src")
  end

  it "fails with a clear message for a missing file" do
    result = PluginSpecHelper.run("slurp", {"src" => tmp_path("does-not-exist-slurp.txt")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("File not found")
  end

  it "appends CPython's errno text to a missing file's error block text" do
    missing = tmp_path("does-not-exist-slurp-errno.txt")

    result = PluginSpecHelper.run("slurp", {"src" => missing})

    result["msg"].as_s.must_equal("File not found: #{missing}")
    result["_ansible_error_detail"].as_s.must_equal(
      "File not found: #{missing}: [Errno 2] No such file or directory: '#{missing}'")
  end

  it "appends CPython's errno text when src is a directory" do
    dir = tmp_path("slurp_dir_errno")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("slurp", {"src" => dir})

    result["msg"].as_s.must_equal("Source is a directory and must be a file: #{dir}")
    result["_ansible_error_detail"].as_s.must_equal(
      "Source is a directory and must be a file: #{dir}: [Errno 21] Is a directory: '#{dir}'")
  end

  it "fails with a clear message when src is a directory" do
    dir = tmp_path("slurp_dir")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("slurp", {"src" => dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("directory")
  end
end
