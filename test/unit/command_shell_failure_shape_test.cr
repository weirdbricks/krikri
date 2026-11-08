require "../minitest_helper"

# Failure-path result SHAPE parity for command/shell, found via the
# podman-diff harness (testing/podman-diff/cases/command_edge_cases.yml):
# Ansible's command/shell module fails these cases inside
# AnsibleModule.run_command / before any process spawns, so the
# registered result keeps the FULL command-module shape (cmd, stdout,
# stdout_lines, stderr, stderr_lines, start, end, delta) - with rc
# absent for a chdir failure (its rc is None, and ansible-core 2.21's
# result normalization drops null-valued declared fields) or the raw
# OSError errno for a bad shell executable - and changed stays FALSE.
describe "command/shell failure-path result shape" do
  describe "command with a nonexistent chdir" do
    it "fails with the full result shape and NO rc key (ansible drops the null rc)" do
      result = PluginSpecHelper.run("command", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      # ansible-core 2.21.6's rendered/registered result has no rc at all
      # (command.py seeds rc=None, but the controller's result
      # normalization omits null-valued declared fields). start/end/delta
      # are extra keys, not declared fields, so they survive as nulls.
      result.as_h.has_key?("rc").must_equal(false)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      result["stdout_lines"].as_a.must_be_empty
      result["stderr_lines"].as_a.must_be_empty
      result["start"].raw.must_be_nil
      result["end"].raw.must_be_nil
      result["delta"].raw.must_be_nil
      # Ansible's fatal msg is the generic text; the path lives only in
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
    it "fails with changed false and NO rc key before the shell runs (ansible drops the null rc)" do
      result = PluginSpecHelper.run("shell", {
        "cmd"   => "pwd",
        "chdir" => "/nonexistent-krikri-spec-dir-zzz",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      # ansible-core 2.21.6 omits the null-valued rc field from the result;
      # emitting `rc: null` here was the issue #947 shell divergence.
      result.as_h.has_key?("rc").must_equal(false)
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

  # Issue #947 (kpg 000015-shell-chaos): a chdir failure must reproduce
  # ansible-core 2.21.6's rendered key set EXACTLY - the null-valued `rc`
  # field is dropped by ansible's result normalization, so a registered or
  # displayed result has no rc key. This checks the whole key set (not just
  # rc's absence) so any future drift in the failed-chdir shape is caught.
  describe "chdir failure rendered key set" do
    it "matches ansible's key set with no rc for both command and shell" do
      expected = %w[changed cmd delta end exception failed msg start stderr stderr_lines stdout stdout_lines]
      {"command" => "true", "shell" => "/bin/true"}.each do |plugin, cmd|
        result = PluginSpecHelper.run(plugin, {
          "cmd"   => cmd,
          "chdir" => "/nonexistent-krikri-spec-dir-zzz",
        })

        result["failed"].as_bool.must_equal(true)
        result.as_h.has_key?("rc").must_equal(false)
        (expected - result.as_h.keys).must_be_empty
      end
    end
  end

  # Issue #960 (adarnimrod.openwrt-bootstrap): real's raw action hands the
  # bare command to the CONNECTION (raw.py defaults `executable` to False,
  # so the action base never adds its `<exe> -c` wrap unless the task names
  # one), and sshd runs it through the login shell - bash on the round
  # hosts - so a missing command lands on the merged pty stream as "bash:
  # line 1: X: command not found". Aliasing raw onto the shell plugin
  # wrapped it in the module-side /bin/sh instead, which only coincides on
  # the LOCAL connection (shell=True spawns /bin/sh there): over ssh
  # krikri's result said "/bin/sh: 1: opkg: not found" where real's said
  # "bash: line 1: opkg: command not found". Only REMOTE raw (the
  # __raw_pty_merge marker) takes the login shell.
  describe "remote raw dispatch" do
    it "runs the command through the login shell, not a module-side /bin/sh" do
      result = PluginSpecHelper.run("shell", {
        "cmd"                   => "nosuchcmd_krikri_960_zzz",
        "strip_empty_ends"      => "false",
        "_ansible_raw_dispatch" => "1",
        "__raw_pty_merge"       => "1",
      })

      result["rc"].as_i.must_equal(127)
      result["stdout"].as_s.must_equal("bash: line 1: nosuchcmd_krikri_960_zzz: command not found\r\n")
      result["stderr"].as_s.must_equal("")
    end

    it "keeps an explicit executable: as the shell (real raw forwards it)" do
      result = PluginSpecHelper.run("shell", {
        "cmd"                   => "nosuchcmd_krikri_960_zzz",
        "executable"            => "/bin/sh",
        "strip_empty_ends"      => "false",
        "_ansible_raw_dispatch" => "1",
        "__raw_pty_merge"       => "1",
      })

      result["rc"].as_i.must_equal(127)
      result["stdout"].as_s.must_equal("/bin/sh: 1: nosuchcmd_krikri_960_zzz: not found\r\n")
    end

    it "leaves local raw on the module-side /bin/sh dash reports" do
      result = PluginSpecHelper.run("shell", {
        "cmd"                   => "nosuchcmd_krikri_960_zzz",
        "strip_empty_ends"      => "false",
        "_ansible_raw_dispatch" => "1",
      })

      result["rc"].as_i.must_equal(127)
      result["stderr"].as_s.must_equal("/bin/sh: 1: nosuchcmd_krikri_960_zzz: not found\n")
    end
  end
end
