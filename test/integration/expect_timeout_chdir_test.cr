require "../minitest_helper"
require "file_utils"
require "json"

# expect's own body checks that real performs AFTER the pexpect gate but
# that this plugin used to skip, live-verified against ansible-playbook
# 2.19.11 on this host (2026-10-01 - krikri-playbook generator round 33
# re-sweep, cases #300/#303/#305/#309; the round itself could only see the
# pexpect message because its container has no pexpect):
#
#   - `timeout` is declared `type: raw`, so a non-numeric one gets no
#     argument-spec error - expect.py's own check_type_int rejects it in
#     the module body, BEFORE the empty-command check;
#   - `os.chdir(os.path.abspath(chdir))` has no try/except, so an
#     unusable chdir is an uncaught OSError the controller reports as
#     "Task failed: Module failed: <errno text>", before the
#     creates/removes guards are looked at.

describe "expect timeout conversion" do
  it "fails a non-numeric timeout with real's check_type_int wording" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "echo hi",
      "responses" => {"x" => "y"}.to_json,
      "timeout"   => "krikri_not_a_number",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'timeout' is of type <class 'str'> and we were unable to convert to int: " \
      "\"'krikri_not_a_number'\" cannot be converted to an int")
  end

  it "beats the empty-command check, like real's ordering" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "   ",
      "responses" => {"x" => "y"}.to_json,
      "timeout"   => "krikri_not_a_number",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("cannot be converted to an int")
  end

  it "still accepts a numeric timeout, and defaults to 30 when it is absent" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "/bin/echo krikri-ok",
      "responses" => {"x" => "y"}.to_json,
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.must_include("krikri-ok")

    numeric = PluginSpecHelper.run("expect", {
      "command"   => "/bin/echo krikri-ok",
      "responses" => {"x" => "y"}.to_json,
      "timeout"   => "7",
    })

    falsey?(numeric["failed"]?.try(&.as_bool)).must_equal(true)
    numeric["stdout"].as_s.must_include("krikri-ok")
  end
end

describe "expect chdir" do
  it "fails with ENOTDIR when chdir names a regular file" do
    file = PluginSpecHelper.tmp_path("expect-chdir-not-a-dir")
    File.write(file, "")

    result = PluginSpecHelper.run("expect", {
      "command"   => "echo hi",
      "responses" => {"x" => "y"}.to_json,
      "chdir"     => file,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: [Errno 20] Not a directory: '#{file}'")
  end

  it "fails with ENOENT when chdir does not exist" do
    missing = File.join(PluginSpecHelper.tmp_path("expect-chdir"), "no-such-dir")

    result = PluginSpecHelper.run("expect", {
      "command"   => "echo hi",
      "responses" => {"x" => "y"}.to_json,
      "chdir"     => missing,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: [Errno 2] No such file or directory: '#{missing}'")
  end

  it "beats the creates/removes skip, like real's ordering" do
    missing = File.join(PluginSpecHelper.tmp_path("expect-chdir-skip"), "no-such-dir")
    exists = PluginSpecHelper.tmp_path("expect-chdir-skip-guard")
    File.write(exists, "")

    result = PluginSpecHelper.run("expect", {
      "command"   => "echo hi",
      "responses" => {"x" => "y"}.to_json,
      "chdir"     => missing,
      "creates"   => exists,
    })

    # Real chdirs before the creates check, so the skip never happens.
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("No such file or directory")
  end

  it "runs the command in the given directory when it is usable" do
    dir = PluginSpecHelper.tmp_path("expect-chdir-ok")
    FileUtils.mkdir_p(dir)

    result = PluginSpecHelper.run("expect", {
      "command"   => "/bin/pwd",
      "responses" => {"x" => "y"}.to_json,
      "chdir"     => dir,
      "timeout"   => "5",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.must_include(dir)
  end
end
