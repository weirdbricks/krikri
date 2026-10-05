require "../minitest_helper"
require "file_utils"
require "../../src/krikri/task_executor"

# Regression spec (sweep29 000034-copy-chaos): a `copy:` with a TRUTHY
# remote_src hands the whole task to the copy module on the target - the
# action plugin never resolves src on the controller, not even for a
# relative or non-string literal src. Previously only the four plain
# spellings ("true"/"yes"/"1"/"on") matched the gate, so a YAML-bool
# `remote_src: true` (wired as a marked non-string literal) fell through
# to the controller lookup and failed with "Could not find or access"
# (leaking the internal non-string marker into the searched paths), where
# Ansible fails on the target with "Module failed: Source <src> not found"
# or, with unsupported parameters present, the module's
# Unsupported-parameters error first.
#
# Executor side: exercised through a subclass (Crystal private methods are
# callable from subclasses via the implicit receiver), same trick
# copy_missing_src_test.cr uses. No remote host needed: the old bug fired
# the controller-side lookup before any upload.
private class RemoteSrcCopyProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, host, vars_context)
    inline_copy_source_content(task, params, host, vars_context)
  end
end

describe "copy: truthy remote_src skips the controller-side src lookup" do
  it "leaves a marked-literal src untouched (no controller failure result)" do
    task = Krikri::Task.new("Copy int src", "ansible.builtin.copy")
    host = Krikri::Host.new("spec-host", "root", 1)
    params = {
      "src"        => Krikri::NON_STRING_PARAM_PREFIX + "42",
      "dest"       => "/tmp/kpg-work/out1.txt",
      "remote_src" => Krikri::NON_STRING_PARAM_PREFIX + "true",
    }

    result = RemoteSrcCopyProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    # The point of the regression: NO failed JSON result comes back - the
    # module (the plugin binary) owns the failure now, so the params pass
    # through unchanged.
    result.must_be_instance_of(Hash(String, String))
  end

  it "still fails a missing src on the controller when remote_src is falsy" do
    task = Krikri::Task.new("Copy missing src", "ansible.builtin.copy")
    host = Krikri::Host.new("spec-host", "root", 1)
    params = {
      "src"        => "no-such-src-spec-zzz.txt",
      "dest"       => "/tmp/kpg-work/out1.txt",
      "remote_src" => "false",
    }

    result = RemoteSrcCopyProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    json = result.as(JSON::Any)
    json["failed"].as_bool.must_equal(true)
    json["msg"].as_s.must_include("Could not find or access 'no-such-src-spec-zzz.txt'")
  end
end

describe "copy plugin: remote_src missing-src message formats the module arg" do
  it "prints a bool src as Python True" do
    result = PluginSpecHelper.run("copy", {
      "dest"       => PluginSpecHelper.tmp_path("copy-remote-src-msg/out.txt"),
      "src"        => Krikri::NON_STRING_PARAM_PREFIX + "true",
      "remote_src" => "true",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Source True not found")
  end

  it "prints an int src as its plain text" do
    result = PluginSpecHelper.run("copy", {
      "dest"       => PluginSpecHelper.tmp_path("copy-remote-src-msg/out2.txt"),
      "src"        => Krikri::NON_STRING_PARAM_PREFIX + "42",
      "remote_src" => "true",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Source 42 not found")
  end

  it "prints a list src with marked members as its Python repr" do
    result = PluginSpecHelper.run("copy", {
      "dest"       => PluginSpecHelper.tmp_path("copy-remote-src-msg/out3.txt"),
      "src"        => "#{Krikri::NON_STRING_MEMBER_PREFIX}4,a",
      "remote_src" => "true",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Source [4, 'a'] not found")
  end
end
