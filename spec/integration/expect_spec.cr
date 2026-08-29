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

  it "does not echo the sent response into captured output by default, matching real Ansible's echo: no default" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(read -p "Password: " pw; echo "pw-was: $pw"),
      "responses" => {"Password:" => "hunter2"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_false
    # The typed response itself ("hunter2") must not appear a second time
    # via terminal echo - only the script's own explicit "pw-was: hunter2"
    # print should be present.
    result["stdout"].as_s.scan("hunter2").size.should eq(1)
  end

  it "echoes the sent response when echo: true is explicitly requested" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(read -p "Password: " pw; echo "pw-was: $pw"),
      "responses" => {"Password:" => "hunter2"}.to_json,
      "timeout"   => "5",
      "echo"      => "true",
    })

    result["failed"].as_bool.should be_false
    # Once from the pty's own echo of the typed line, once from the
    # script's explicit print.
    result["stdout"].as_s.scan("hunter2").size.should eq(2)
  end

  it "cycles through a list of responses as the same prompt reappears, real Ansible's own repeated-prompt idiom" do
    script = %q(
      for item in one two three; do
        read -p "Confirm $item? " ans
        echo "answered $item with $ans"
      done
    )
    result = PluginSpecHelper.run("expect", {
      "command"   => script,
      "responses" => {"Confirm \\w+\\?" => ["yes", "no", "yes"]}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should contain("answered one with yes")
    result["stdout"].as_s.should contain("answered two with no")
    result["stdout"].as_s.should contain("answered three with yes")
  end

  it "runs the child as its own session leader with the pty as controlling terminal" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(read -p "go? " x; echo "sid=$(ps -o sid= -p $$ | tr -d ' ') pid=$$"),
      "responses" => {"go?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_false
    match = result["stdout"].as_s.match!(/sid=(\d+) pid=(\d+)/)
    # A real session leader's own session id equals its own pid - the
    # thing setsid()/TIOCSCTTY exists to arrange, unreachable via a plain
    # inherited pty fd with no fork-time hook (Process.new's own spawn,
    # used before this fix).
    match[1].should eq(match[2])
  end
end
