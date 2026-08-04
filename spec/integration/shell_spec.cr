require "../spec_helper"

# Read-only - just runs plain shell commands and inspects captured output,
# never mutates host state.

describe "shell plugin" do
  it "rstrips a trailing newline from stdout, matching real Ansible's own AnsibleModule.run_command()" do
    result = PluginSpecHelper.run("shell", {"cmd" => "echo hello"})

    result["stdout"].as_s.should eq("hello")
  end

  it "does not strip internal newlines, only the trailing one" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'line1\\nline2\\n'"})

    result["stdout"].as_s.should eq("line1\nline2")
  end

  it "leaves stdout as-is when there is no trailing newline" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'no-newline'"})

    result["stdout"].as_s.should eq("no-newline")
  end

  it "rstrips stderr the same way" do
    result = PluginSpecHelper.run("shell", {"cmd" => "echo oops 1>&2"})

    result["stderr"].as_s.should eq("oops")
  end
end
