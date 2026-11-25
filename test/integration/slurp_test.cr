require "../minitest_helper"
require "file_utils"
require "base64"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "slurp plugin" do
  it "returns a file's content base64-encoded (Ansible always does)" do
    path = tmp_path("slurp_armored.txt")
    File.write(path, "hello slurp")

    result = PluginSpecHelper.run("slurp", {"src" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["encoding"].as_s.must_equal("base64")
    Base64.decode_string(result["content"].as_s).must_equal("hello slurp")
    result["source"].as_s.must_equal(path)
  end

  it "returns raw UTF-8 content with encoding utf-8 for armor=false (2.21 param)" do
    path = tmp_path("slurp_unarmored.txt")
    File.write(path, "plain text")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["encoding"].as_s.must_equal("utf-8")
    result["content"].as_s.must_equal("plain text")
    result["source"].as_s.must_equal(path)
  end

  it "fails armor=false on non-UTF-8 content like the controller's deserializer" do
    path = tmp_path("slurp_armor_binary.bin")
    File.write(path, "\xff\xfe\x00binary")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    result["failed"].as_bool.must_equal(true)
    # Real raises the refusal while deserializing the module result, so the
    # executor wraps it in an AnsibleTaskError: the registered msg carries
    # the "Task failed: " brief, the [ERROR] block text does not.
    result["msg"].as_s.must_equal("Task failed: Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode characters in position 0-1: surrogates not allowed")
    result["_ansible_error_detail"].as_s.must_equal("Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode characters in position 0-1: surrogates not allowed")
  end

  # CPython's codec error counts positions in CHARACTERS of the
  # surrogateescape-decoded string and quotes a single lone surrogate's own
  # escape instead of a range (live-verified vs ansible-core 2.21.6, issue
  # #1801: a binary fixture whose 0xff follows 12 ASCII bytes is reported as
  # position 12, not the byte range krikri used to derive).
  it "reports a single lone surrogate with CPython's character form" do
    path = tmp_path("slurp_single_surrogate.bin")
    File.write(path, "a\u00E9\xFFb")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    result["failed"].as_bool.must_equal(true)
    result["_ansible_error_detail"].as_s.must_equal("Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode character '\\udcff' in position 2: surrogates not allowed")
  end

  it "counts an encoded-surrogate byte run as one surrogate per byte" do
    path = tmp_path("slurp_cesu8.bin")
    File.write(path, "a\xED\xB3\xBFb")

    result = PluginSpecHelper.run("slurp", {"src" => path, "armor" => "false"})

    result["failed"].as_bool.must_equal(true)
    result["_ansible_error_detail"].as_s.must_equal("Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode characters in position 1-3: surrogates not allowed")
  end

  it "accepts the path alias for src" do
    path = tmp_path("slurp_alias.txt")
    File.write(path, "aliased")

    result = PluginSpecHelper.run("slurp", {"path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    Base64.decode_string(result["content"].as_s).must_equal("aliased")
  end

  it "expands a leading ~ in src before reading, like Ansible's path-type argspec" do
    # jesperberth.el_k3s slurps the `~/stable.txt` its get_url task wrote;
    # Ansible's check_type_path expanduser's every `type: path` option, so
    # the read succeeds and both source and msg show the absolute path
    # (issue #1568). The marker lives in the real $HOME and the plugin
    # child inherits the test process's ENV, so the pair holds ENV_MUTEX
    # against concurrent tests that repoint HOME.
    PluginSpecHelper::ENV_MUTEX.synchronize do
      home = ENV["HOME"]? || "/root"
      marker = File.join(home, "krikri-playbook-spec-slurp-tilde-marker")
      File.write(marker, "tilde content")

      begin
        result = PluginSpecHelper.run("slurp", {"src" => "~/krikri-playbook-spec-slurp-tilde-marker"})

        falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
        Base64.decode_string(result["content"].as_s).must_equal("tilde content")
        result["source"].as_s.must_equal(marker)

        missing = PluginSpecHelper.run("slurp", {"path" => "~/krikri-playbook-spec-absent-tilde-marker"})
        missing["msg"].as_s.must_equal("File not found: #{File.join(home, "krikri-playbook-spec-absent-tilde-marker")}")
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end
  end

  it "fails with Ansible's missing-argument message when src is absent" do
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
