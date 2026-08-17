require "../spec_helper"
require "json"

describe "expect plugin" do
  it "answers a single interactive prompt" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(read -p "Continue? " ans; echo "got: $ans"),
      "responses" => {"Continue?" => "yes"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should contain("got: yes")
  end

  it "answers multiple distinct prompts in sequence" do
    script = %q(
      read -p "Name? " name
      read -p "Confirm? " ok
      echo "name=$name confirm=$ok"
    )
    result = PluginSpecHelper.run("expect", {
      "command"   => script,
      "responses" => {"Name?" => "alice", "Confirm?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should contain("name=alice confirm=y")
  end

  it "reports failed: true for a non-zero exit code" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(read -p "go? " x; exit 7),
      "responses" => {"go?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_true
    result["rc"].as_i.should eq(7)
  end

  it "fails clearly when no prompt ever matches (timeout)" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(sleep 5),
      "responses" => {"never-appears" => "x"}.to_json,
      "timeout"   => "1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("timed out")
  end

  it "fails when responses is missing" do
    result = PluginSpecHelper.run("expect", {"command" => "echo hi"})

    result["failed"].as_bool.should be_true
  end
end
