require "../minitest_helper"
require "../../src/krikri/plugin_manager"

# Issue #552 - libre_ops.multi_redis: a batch group that hit a missing plugin
# binary used to be sent again in full, so the `file:` step before the
# missing `service:` step ran twice and reported ok on its second run (the
# first run had already created the directory). Real ansible runs each task
# once, so only the missing step and the steps that never ran may be re-sent.
describe "batch steps to resend after a missing plugin binary" do
  def missing_result(module_name : String) : JSON::Any
    JSON.parse({
      "failed" => true,
      "stdout" => "",
      "stderr" => "bash: line 1: #{Krikri::PluginManager.remote_plugin_dir(nil)}/#{module_name}: No such file or directory",
    }.to_json)
  end

  def ok_result : JSON::Any
    JSON.parse({"changed" => true, "failed" => false, "stdout" => "", "stderr" => ""}.to_json)
  end

  it "resends only the missing step when the steps before it already ran" do
    # file, systemd, service: the script halted at service (no result for
    # anything after it, and the earlier two already ran).
    interpreted = {0 => ok_result, 1 => ok_result, 2 => missing_result("service")} of Int32 => JSON::Any
    Krikri::PluginManager.batch_steps_to_resend(interpreted, ["file", "systemd", "service"], nil)
      .must_equal([2])
  end

  it "also resends the steps that never got a result after the missing one" do
    interpreted = {0 => ok_result, 1 => missing_result("service")} of Int32 => JSON::Any
    Krikri::PluginManager.batch_steps_to_resend(interpreted, ["file", "service", "command"], nil)
      .must_equal([1, 2])
  end

  it "keeps a step that already ran after a missing one with ignore_errors" do
    # The script did not halt at the missing step, so step 1 already ran.
    interpreted = {0 => missing_result("service"), 1 => ok_result} of Int32 => JSON::Any
    Krikri::PluginManager.batch_steps_to_resend(interpreted, ["service", "file"], nil)
      .must_equal([0])
  end

  it "resends nothing when no step reports a missing binary" do
    interpreted = {0 => ok_result} of Int32 => JSON::Any
    Krikri::PluginManager.batch_steps_to_resend(interpreted, ["file", "command"], nil)
      .must_equal([] of Int32)
  end
end
