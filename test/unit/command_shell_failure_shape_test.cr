require "../minitest_helper"

# Failure-path result SHAPE parity for command/shell, found via the
# podman-diff harness (testing/podman-diff/cases/command_edge_cases.yml):
# Ansible's command/shell module fails these cases inside
# AnsibleModule.run_command / before any process spawns, so the
# registered result keeps the FULL command-module shape (cmd, stdout,
# stdout_lines, stderr, stderr_lines, start, end, delta) with rc either
# null (chdir failure) or the raw OSError errno (bad shell executable)
# - and changed stays FALSE. This engine used to return either a bare
# msg-only result (rc key absent entirely -> registered `.rc` reads
# undefined where Ansible hands back null) or a shell "command not
# found" exit code with changed=true.
describe "command/shell failure-path result shape" do
  describe "command with a nonexistent chdir" do
    it "fails with rc null and the full result shape (not a missing rc key)" do
      result = PluginSpecHelper.run("command", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_nil.must_be_nil
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      result["stdout_lines"].as_a.must_be_empty
      result["stderr_lines"].as_a.must_be_empty
      # Ansible 2.19.11's fatal msg is the generic text; the path lives only in
      # the [ERROR] block's detail (carried in _ansible_error_detail)
      result["msg"].as_s.must_equal("Unable to change directory before execution.")
      result["_ansible_error_detail"].as_s.must_include("/nonexistent-krikri-spec-dir-zzz")
    end
  end

  describe "shell with a nonexistent executable" do
    it "fails with changed false and the OSError errno as rc (not a shell exit code)" do
      result = PluginSpecHelper.run("shell", {
        "cmd"        => "echo hi",
        "executable" => "/nonexistent-krikri-spec-shell-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_i.must_equal(2)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
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

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_i.must_equal(13)
    end
  end

  describe "shell with a nonexistent chdir" do
    it "fails with rc null and changed false before the shell runs" do
      result = PluginSpecHelper.run("shell", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_nil.must_be_nil
      result["stdout"].as_s.must_equal("")
    end
  end

  describe "shell with an existing executable (unchanged behavior)" do
    it "still runs through the requested shell" do
      result = PluginSpecHelper.run("shell", {
        "cmd"        => "echo shell-ok",
        "executable" => "/bin/bash",
      })

      # command/shell are the exception to "success results carry no failed
      # key": their exit_json result reports `failed: false` explicitly
      # (live-compared against 2.19.11 via a registered result dump).
      result["failed"].as_bool.must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["rc"].as_i.must_equal(0)
      result["stdout"].as_s.must_equal("shell-ok")
    end
  end

  # A spawn that never started is failed by Ansible's run_command with its
  # OWN shape, not the module's: the fixed message "Error executing
  # command.", the OS errno as rc, empty stdout/stderr, and `cmd` set to
  # the shlex-quoted join of the argv it tried to spawn (a STRING, not
  # the list a successful run reports). The OSError text only reaches the
  # [ERROR] block. Found by the kpg30 sweep on a `command:` task whose
  # cmd: was not a string; live-verified against 2.19.11 for both
  # modules, e.g. `command: /does/not/exist/anywhere` failing with
  # {"changed": false, "cmd": "/does/not/exist/anywhere", "msg": "Error
  # executing command.", "rc": 2, "stderr": "", "stdout": ""}.
  describe "command with a nonexistent executable" do
    it "fails with Ansible's run_command spawn shape, not a changed result with the OSError text as stderr" do
      result = PluginSpecHelper.run("command", {"cmd" => "/does/not/exist/anywhere --version"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Error executing command.")
      result["rc"].as_i.must_equal(2)
      result["cmd"].as_s.must_equal("/does/not/exist/anywhere --version")
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      result["stdout_lines"].as_a.must_be_empty
      result["stderr_lines"].as_a.must_be_empty
      # Python's str(OSError) on the bytes argv run_command hands Popen -
      # this is what the [ERROR] block composes into "Error executing
      # command: <exception>".
      result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/does/not/exist/anywhere'")
    end

    it "shlex-quotes an argv element that needs it in the reported cmd" do
      result = PluginSpecHelper.run("command", {"cmd" => "/does/not/exist/anywhere 'a b'"})

      result["cmd"].as_s.must_equal("/does/not/exist/anywhere 'a b'")
    end
  end

  describe "shell with a nonexistent executable (run_command's own failure shape)" do
    it "reports the fixed message, the errno as rc and the shlex-joined shell argv as cmd" do
      result = PluginSpecHelper.run("shell", {
        "cmd"        => "echo hi",
        "executable" => "/nonexistent-krikri-spec-shell-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Error executing command.")
      result["rc"].as_i.must_equal(2)
      result["cmd"].as_s.must_equal("/nonexistent-krikri-spec-shell-zzz -c 'echo hi'")
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/nonexistent-krikri-spec-shell-zzz'")
    end

    it "reports EACCES (13) with the errno named in the exception for a non-executable shell" do
      not_executable = File.tempname("krikri-shell-exec-not-exec")
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

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Error executing command.")
      result["rc"].as_i.must_equal(13)
      result["exception"].as_s.must_equal("[Errno 13] Permission denied: b'#{not_executable}'")
    end
  end
end
