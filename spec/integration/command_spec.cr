require "../spec_helper"

# Read-only - just runs plain commands and inspects captured output, never
# touches the filesystem outside spec/tmp or mutates host state. Commands
# are chosen to need no shell quoting, since command.cr's own parse_command
# is a naive whitespace split (documented limitation, not this fix's
# concern).

describe "command plugin" do
  it "rstrips a trailing newline from stdout, matching real Ansible's own AnsibleModule.run_command()" do
    result = PluginSpecHelper.run("command", {"cmd" => "echo hello"})

    result["stdout"].as_s.should eq("hello")
  end

  it "does not strip internal newlines, only the trailing one" do
    result = PluginSpecHelper.run("command", {"cmd" => "seq 1 3"})

    result["stdout"].as_s.should eq("1\n2\n3")
  end

  it "leaves stdout as-is when there is no trailing newline" do
    result = PluginSpecHelper.run("command", {"cmd" => "printf %s no-newline"})

    result["stdout"].as_s.should eq("no-newline")
  end
end
