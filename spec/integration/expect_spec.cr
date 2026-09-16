require "../spec_helper"
require "json"

describe "expect plugin" do
  it "answers a single interactive prompt" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "Continue? " ans; echo "got: $ans"'),
      "responses" => {"Continue?" => "yes"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should contain("got: yes")
  end

  it "answers multiple distinct prompts in sequence" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "Name? " name; read -p "Confirm? " ok; echo "name=$name confirm=$ok"'),
      "responses" => {"Name?" => "alice", "Confirm?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should contain("name=alice confirm=y")
  end

  it "reports failed: true for a non-zero exit code" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "go? " x; exit 7'),
      "responses" => {"go?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_true
    result["rc"].as_i.should eq(7)
    result["msg"].as_s.should eq("non-zero return code")
  end

  it "fails with real's 'command exceeded timeout' wording and rc None when no prompt ever matches" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "/bin/sleep 5",
      "responses" => {"never-appears" => "x"}.to_json,
      "timeout"   => "1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("command exceeded timeout")
    result["rc"].raw.should be_nil
  end

  it "fails when responses is missing, with parameters.py's plural wording" do
    result = PluginSpecHelper.run("expect", {"command" => "echo hi"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: responses")
  end

  it "fails with parameters.py's plural wording when command is missing" do
    result = PluginSpecHelper.run("expect", {"responses" => {"x" => "y"}.to_json})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: command")
  end

  it "rejects an all-whitespace command with rc=256 'no command given' like real expect.py" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "   ",
      "responses" => {"x" => "y"}.to_json,
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("no command given")
    result["rc"].as_i.should eq(256)
  end

  it "does not echo the sent response into captured output by default, matching real Ansible's echo: no default" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "Password: " pw; echo "pw-was: $pw"'),
      "responses" => {"Password:" => "hunter2"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    # The typed response itself ("hunter2") must not appear a second time
    # via terminal echo - only the script's own explicit "pw-was: hunter2"
    # print should be present.
    result["stdout"].as_s.scan("hunter2").size.should eq(1)
  end

  it "echoes the sent response when echo: true is explicitly requested" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "Password: " pw; echo "pw-was: $pw"'),
      "responses" => {"Password:" => "hunter2"}.to_json,
      "timeout"   => "5",
      "echo"      => "true",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    # Once from the pty's own echo of the typed line, once from the
    # script's explicit print.
    result["stdout"].as_s.scan("hunter2").size.should eq(2)
  end

  it "answers a list of responses in order as the same prompt reappears" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'for item in one two three; do read -p "Confirm $item? " ans; echo "answered $item with $ans"; done'),
      "responses" => {"Confirm \\w+\\?" => ["yes", "no", "yes"]}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should contain("answered one with yes")
    result["stdout"].as_s.should contain("answered two with no")
    result["stdout"].as_s.should contain("answered three with yes")
  end

  it "fails with real's 'No remaining responses' wording (changed=false) when a list response exhausts" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "A? " x; read -p "B? " y'),
      "responses" => {"\\? $" => ["only-one"]}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("No remaining responses for '\\? $'")
  end

  it "resends a plain string response on every prompt match (real's static-bytes behavior)" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'for item in one two; do read -p "Confirm $item? " ans; echo "answered $item with $ans"; done'),
      "responses" => {"Confirm \\w+\\?" => "yes"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should contain("answered one with yes")
    result["stdout"].as_s.should contain("answered two with yes")
  end

  it "does NOT run the command through a shell - real pexpect shlex-splits it, so metacharacters stay literal" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "echo $HOME > /tmp/krikri-expect-spec-noshell",
      "responses" => {"x" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    # The whole string arrived as literal argv to echo - no $HOME
    # expansion, no redirect.
    result["stdout"].as_s.should eq("$HOME > /tmp/krikri-expect-spec-noshell")
    File.exists?("/tmp/krikri-expect-spec-noshell").should be_false
  end

  it "fails with pexpect's own wording when the executable does not exist" do
    result = PluginSpecHelper.run("expect", {
      "command"   => "krikri-expect-no-such-bin --flag",
      "responses" => {"x" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("The command was not found or was not executable: krikri-expect-no-such-bin.")
  end

  it "skips via creates with NO msg and rc=0, like real expect.py (unlike the command module)" do
    existing = File.tempname("krikri-expect-creates", "")
    File.write(existing, "x")
    begin
      result = PluginSpecHelper.run("expect", {
        "command"   => "/bin/true",
        "responses" => {"x" => "y"}.to_json,
        "creates"   => existing,
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_false
      result["rc"].as_i.should eq(0)
      result["stdout"].as_s.should eq("skipped, since #{existing} exists")
      result["msg"]?.should be_nil
    ensure
      File.delete(existing) rescue nil
    end
  end

  it "runs the child as its own session leader with the pty as controlling terminal" do
    result = PluginSpecHelper.run("expect", {
      "command"   => %q(/bin/bash -c 'read -p "go? " x; echo "sid=$(ps -o sid= -p $$ | tr -d " ") pid=$$"'),
      "responses" => {"go?" => "y"}.to_json,
      "timeout"   => "5",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    match = result["stdout"].as_s.match!(/sid=(\d+) pid=(\d+)/)
    # A real session leader's own session id equals its own pid - the
    # thing setsid()/TIOCSCTTY exists to arrange, unreachable via a plain
    # inherited pty fd with no fork-time hook (Process.new's own spawn,
    # used before this fix).
    match[1].should eq(match[2])
  end
end
