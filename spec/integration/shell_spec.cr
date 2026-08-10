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

  it "preserves the command's own embedded single quotes when executable: names a custom shell" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # "Get installed Vault version" task (`args: {executable: /bin/bash}`,
    # cmd containing `cut -d' ' -f2 | tr -d 'v'`) - a non-default
    # executable: wraps the whole command in `-c '...'`, and naively
    # embedding a command that has its own single quotes prematurely
    # closed that outer quoting, corrupting everything after the first
    # embedded quote ("cut: option requires an argument -- 'd'").
    result = PluginSpecHelper.run("shell", {
      "cmd"        => "echo 'v1.2.3' | cut -d' ' -f2 | tr -d 'v'",
      "executable" => "/bin/bash",
    })

    result["stdout"].as_s.should eq("1.2.3")
  end
end
