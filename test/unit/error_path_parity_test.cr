require "../minitest_helper"
require "file_utils"

private def scratch_dir : String
  dir = PluginSpecHelper.tmp_path("error-path-parity")
  FileUtils.mkdir_p(dir)
  dir
end

# Error-path shapes found by the differential fuzzer (krikri-playbook-generator)
# vs real ansible-core 2.19.11: every expectation below was checked against
# real ansible's own module source / a live run, not guessed.
describe "error-path parity with real ansible (fuzzer findings)" do
  it "replace/blockinfile/lineinfile report a missing file with ' !' and rc 257" do
    missing = File.join(scratch_dir, "no-such-file-zzz")

    replace = PluginSpecHelper.run("replace", {"path" => missing, "regexp" => "a", "replace" => "b"})
    replace["failed"].as_bool.must_equal(true)
    replace["msg"].as_s.must_equal("Path #{missing} does not exist !")
    replace["rc"].as_i.must_equal(257)

    block = PluginSpecHelper.run("blockinfile", {"path" => missing, "block" => "x"})
    block["msg"].as_s.must_equal("Path #{missing} does not exist !")
    block["rc"].as_i.must_equal(257)

    line = PluginSpecHelper.run("lineinfile", {"path" => missing, "line" => "x"})
    line["msg"].as_s.must_equal("Destination #{missing} does not exist !")
    line["rc"].as_i.must_equal(257)
  end

  it "find failure dumps carry the offending age/size value" do
    age = PluginSpecHelper.run("find", {"paths" => scratch_dir, "age" => "banana"})
    age["msg"].as_s.must_equal("failed to process age")
    age["age"].as_s.must_equal("banana")

    size = PluginSpecHelper.run("find", {"paths" => scratch_dir, "size" => "banana"})
    size["msg"].as_s.must_equal("failed to process size")
    size["size"].as_s.must_equal("banana")
  end

  it "find turns a non-directory search path into real's module warning" do
    file = File.join(scratch_dir, "a-file")
    File.write(file, "x")
    result = PluginSpecHelper.run("find", {"paths" => file})
    result["skipped_paths"][file].as_s.must_equal("'#{file}' is not a directory")
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Skipped '#{file}' path due to this access issue: '#{file}' is not a directory\n"])
  end

  it "hostname use: macosx fails like get_bin_path('scutil') does on Linux" do
    result = PluginSpecHelper.run("hostname", {"name" => "example", "use" => "macosx"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to find required executable "scutil" in paths: /)
  end

  it "assemble with remote_src: false and a non-directory src is an action-level failure" do
    file = File.join(scratch_dir, "src-file")
    File.write(file, "x")
    result = PluginSpecHelper.run("assemble", {"src" => file, "dest" => File.join(scratch_dir, "out"), "remote_src" => "false"})
    result["msg"].as_s.must_equal("Source (#{file}) is not a directory")
    result["_ansible_action_level"].as_bool.must_equal(true)

    # default remote_src: the MODULE reports it (no action-level flag)
    module_level = PluginSpecHelper.run("assemble", {"src" => file, "dest" => File.join(scratch_dir, "out")})
    module_level["msg"].as_s.must_equal("Source (#{file}) is not a directory")
    module_level["_ansible_action_level"]?.must_be_nil
  end

  it "command: a bad chdir wins over a creates: that would skip the task" do
    missing = File.join(scratch_dir, "no-such-dir")
    result = PluginSpecHelper.run("command", {"cmd" => "true", "chdir" => missing, "creates" => "/"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unable to change directory before execution.")
  end

  it "fetch: a missing src fails with changed+msg only and the module text for the [ERROR] block" do
    missing = File.join(scratch_dir, "no-such-src")
    result = PluginSpecHelper.run("fetch", {"src" => missing, "dest" => File.join(scratch_dir, "d") + "/"})
    result["msg"].as_s.must_equal("the remote file does not exist, not transferring, ignored")
    result["file"]?.must_be_nil
    result["_ansible_error_detail"].as_s.must_equal(
      "File not found: #{missing}: [Errno 2] No such file or directory: '#{missing}'")
  end
end
