require "../spec_helper"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"

# pause runs as a controller-side action plugin (no target module, same
# as debug/assert/fail/set_fact) - see PauseActionPlugin. These specs
# pin the param surface against real ansible.builtin.pause's
# argument_spec: echo (bool, default true), minutes (int, mutually
# exclusive with seconds), seconds (int), prompt (str).
private def run_pause(params : Hash(String, String)) : Krikri::ActionResult
  caller_host = Krikri::Host.new("control1")
  plugin = Krikri::PauseActionPlugin.new(params, Hash(String, JSON::Any).new, caller_host)
  plugin.execute
end

private def final_json(result : Krikri::ActionResult) : JSON::Any
  json = result.final_result
  json.should_not be_nil
  json.as(JSON::Any)
end

describe "PauseActionPlugin" do
  it "fails minutes and seconds together with real Ansible's exact error text" do
    result = run_pause({"seconds" => "1", "minutes" => "1"})

    result.success?.should be_true
    final = final_json(result)
    final.as_h["failed"].as_bool.should be_true
    final.as_h["msg"].as_s.should eq("parameters are mutually exclusive: minutes|seconds")
  end

  it "fails minutes and seconds together even when one is zero (verified against real ansible-playbook)" do
    result = run_pause({"seconds" => "0", "minutes" => "0"})

    final_json(result).as_h["failed"].as_bool.should be_true
  end

  it "reports the prompt text as the visible output for a prompt-only pause" do
    result = run_pause({"prompt" => "Press Enter to continue"})

    result.success?.should be_true
    final = final_json(result)
    final.as_h["failed"]?.try(&.as_bool).should be_falsey
    final.as_h["stdout"].as_s.should eq("Press Enter to continue")
    final.as_h["delta"].as_i64.should eq(0)
  end

  it "keeps the countdown message as stdout when prompt is combined with seconds" do
    result = run_pause({"prompt" => "Waiting a bit", "seconds" => "0"})

    final = final_json(result)
    final.as_h["failed"]?.try(&.as_bool).should be_falsey
    final.as_h["stdout"].as_s.should eq("Paused for 0.0 seconds")
  end

  it "keeps the countdown message as stdout when prompt is combined with minutes" do
    result = run_pause({"prompt" => "Waiting a bit", "minutes" => "0"})

    final = final_json(result)
    final.as_h["failed"]?.try(&.as_bool).should be_falsey
    final.as_h["stdout"].as_s.should eq("Paused for 0.0 minutes")
  end

  it "never reports changed" do
    result = run_pause({"seconds" => "0"})

    final_json(result).as_h["changed"].as_bool.should be_false
  end

  it "defaults echo to true" do
    result = run_pause({"seconds" => "0"})

    final_json(result).as_h["echo"].as_bool.should be_true
  end

  it "honors echo: false" do
    result = run_pause({"seconds" => "0", "echo" => "false"})

    final_json(result).as_h["echo"].as_bool.should be_false
  end

  it "reports delta as integer seconds in the result" do
    result = run_pause({"seconds" => "0"})

    final = final_json(result)
    final.as_h["delta"].as_i64.should eq(0)
    final.as_h["user_input"].as_s.should eq("")
  end
end
