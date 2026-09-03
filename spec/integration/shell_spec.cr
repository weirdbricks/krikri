require "../spec_helper"
require "file_utils"

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

  it "creates: accepts a GLOB pattern and reports an ordinary ok result, not a skip" do
    # Same real bug as command:'s own copy (appsilon.mount_efs's
    # `creates: ".../amazon-efs-utils*deb"`) - see command_spec.cr's
    # identical case for the full rationale. shell:'s own creates:
    # check went through a DIFFERENT (also literal-only) helper
    # (remote_file_exists?) before this fix.
    dir = File.tempname("shell-creates-glob-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "amazon-efs-utils_1.2.3.deb"), "")

    result = PluginSpecHelper.run("shell", {"cmd" => "echo should-be-skipped", "creates" => File.join(dir, "amazon-efs-utils*.deb")})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Did not run command since")
    result.as_h.has_key?("skipped").should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
