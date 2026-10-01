require "../minitest_helper"
require "../../src/krikri/task_executor"

# Regression (KNOWN_MISSING "Open, known" item, live-verified vs real
# ansible-core 2.19.11): a registered FAILED copy: result keeps real's
# always-present "diff" key - an empty LIST - on every module-level failure
# kind (the missing-destination-directory failure and the module's own
# argspec/bool-conversion failure alike). Krikri omitted the key on failed
# results. Action-level failures (e.g. the controller-side src: miss, the
# src+content conflict) carry NO diff key in real, and neither do other
# modules' argspec failures - those shapes must stay diffless.

private class CopyArgspecProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, vars_context)
    argspec_validation_result(task, params, vars_context, false)
  end
end

describe "failed copy result keeps the always-present diff key" do
  it "adds diff: [] to the module-level failure for a missing destination directory" do
    dest = PluginSpecHelper.tmp_path("no-such-dir/dest.txt")

    result = PluginSpecHelper.run("copy", {"content" => "x", "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not exist")
    result["diff"].as_a.must_equal([] of JSON::Any)
  end

  it "adds diff: [] to an argspec bool-conversion failure inside the plugin binary" do
    dest = PluginSpecHelper.tmp_path("bool-fail.txt")

    result = PluginSpecHelper.run("copy", {"content" => "x", "dest" => dest, "local_follow" => "maybe"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("is not a valid boolean")
    result["diff"].as_a.must_equal([] of JSON::Any)
  end

  it "adds diff: [] to the controller-simulated argspec failure of copy" do
    task = Krikri::Task.new("Bad copy bool", "ansible.builtin.copy")
    host = Krikri::Host.new("spec-host", "root", 1)
    params = {"content" => "x", "dest" => "/tmp/spec/copy-diff.txt", "local_follow" => "maybe"}

    result = CopyArgspecProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, {} of String => JSON::Any)

    result.must_be_instance_of(JSON::Any)
    json = result.as(JSON::Any)
    json["failed"].as_bool.must_equal(true)
    json["diff"].as_a.must_equal([] of JSON::Any)
  end

  it "keeps diff out of the controller-simulated argspec failure of another module" do
    task = Krikri::Task.new("Bad lineinfile bool", "ansible.builtin.lineinfile")
    host = Krikri::Host.new("spec-host", "root", 1)
    params = {"path" => "/tmp/spec/lineinfile-diff.txt", "line" => "x", "create" => "maybe"}

    result = CopyArgspecProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, {} of String => JSON::Any)

    result.must_be_instance_of(JSON::Any)
    json = result.as(JSON::Any)
    json["failed"].as_bool.must_equal(true)
    json["diff"]?.must_be_nil
  end
end
