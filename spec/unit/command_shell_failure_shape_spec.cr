require "../spec_helper"

# Failure-path result SHAPE parity for command/shell, found via the
# podman-diff harness (testing/podman-diff/cases/command_edge_cases.yml):
# real Ansible's command/shell module fails these cases inside
# AnsibleModule.run_command / before any process spawns, so the
# registered result keeps the FULL command-module shape (cmd, stdout,
# stdout_lines, stderr, stderr_lines, start, end, delta) with rc either
# null (chdir failure) or the raw OSError errno (bad shell executable)
# - and changed stays FALSE. This engine used to return either a bare
# msg-only result (rc key absent entirely -> registered `.rc` reads
# undefined where real Ansible hands back null) or a shell "command not
# found" exit code with changed=true.
describe "command/shell failure-path result shape" do
  describe "command with a nonexistent chdir" do
    it "fails with rc null and the full result shape (not a missing rc key)" do
      result = PluginSpecHelper.run("command", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["rc"].as_nil.should be_nil
      result["stdout"].as_s.should eq("")
      result["stderr"].as_s.should eq("")
      result["stdout_lines"].as_a.should be_empty
      result["stderr_lines"].as_a.should be_empty
      result["msg"].as_s.should contain("/nonexistent-krikri-spec-dir-zzz")
    end
  end

  describe "shell with a nonexistent executable" do
    it "fails with changed false and the OSError errno as rc (not a shell exit code)" do
      result = PluginSpecHelper.run("shell", {
        "cmd"        => "echo hi",
        "executable" => "/nonexistent-krikri-spec-shell-zzz",
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["rc"].as_i.should eq(2)
      result["stdout"].as_s.should eq("")
      result["stderr"].as_s.should eq("")
    end

    it "fails with EACCES (13) when the executable exists but is not executable" do
      not_executable = File.tempname("krikri-shell-exec")
      File.write(not_executable, "#!/bin/sh\n")
      File.chmod(not_executable, 0o644)
      begin
        result = PluginSpecHelper.run("shell", {
          "cmd"        => "echo hi",
          "executable" => not_executable,
        })
      ensure
        File.delete(not_executable)
      end

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["rc"].as_i.should eq(13)
    end
  end

  describe "shell with a nonexistent chdir" do
    it "fails with rc null and changed false before the shell runs" do
      result = PluginSpecHelper.run("shell", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["rc"].as_nil.should be_nil
      result["stdout"].as_s.should eq("")
    end
  end

  describe "shell with an existing executable (unchanged behavior)" do
    it "still runs through the requested shell" do
      result = PluginSpecHelper.run("shell", {
        "cmd"        => "echo shell-ok",
        "executable" => "/bin/bash",
      })

      # A successful module's wire result never carries `failed` at all
      # (only fail_json adds it) - see BasePlugin#to_json.
      result["failed"]?.should be_nil
      result["changed"].as_bool.should be_true
      result["rc"].as_i.should eq(0)
      result["stdout"].as_s.should eq("shell-ok")
    end
  end
end
