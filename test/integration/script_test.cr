require "../minitest_helper"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def sc_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "script plugin" do
  # Real's script ACTION captures stdout/stderr and returns them
  # UNSTRIPPED (ansible-core 2.19.11, live-verified): unlike the command
  # module (strip_empty_ends: true), the trailing "\n" survives. Every
  # exact stdout/stderr assertion below pins the untouched trailing
  # newline to lock that against regression.
  it "executes a script and captures its stdout" do
    path = sc_path("script_echo.sh")
    File.write(path, "#!/bin/sh\necho hello-from-script\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("hello-from-script\n")
    result["rc"].as_i.must_equal(0)
  end

  it "passes trailing arguments through to the script" do
    path = sc_path("script_args.sh")
    File.write(path, "#!/bin/sh\necho \"got: $1 $2\"\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => "#{path} one two"})

    result["stdout"].as_s.must_equal("got: one two\n")
  end

  it "reports failed: true for a non-zero exit code" do
    path = sc_path("script_fail.sh")
    File.write(path, "#!/bin/sh\nexit 3\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path})

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i.must_equal(3)
  end

  it "skips when creates: already exists" do
    path = sc_path("script_creates.sh")
    File.write(path, "#!/bin/sh\ntouch #{sc_path("script_creates_marker")}\n")
    File.chmod(path, 0o755)
    marker = sc_path("script_creates_marker")
    File.write(marker, "already here")

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => marker})

    result["changed"].as_bool.must_equal(false)
    File.delete(marker)
  end

  # Ansible's script ACTION gates on the shell's `test -e` / File.exists?
  # semantics: it follows symlinks, so a DANGLING one does not satisfy a
  # creates: gate (found via hesidoryn.python-coreos, issue #1648 - the
  # role's failing bootstrap links /opt/bin/python to a never-installed
  # ActivePython and krikri's glob-based gate skipped the re-run).
  it "runs a creates: gate pointing at a dangling symlink" do
    path = sc_path("script_creates_dangling.sh")
    File.write(path, "#!/bin/sh\necho ran-with-dangling-gate\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_creates_dangling_gate")
    File.delete?(gate)
    File.symlink("/nonexistent-activepython", gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate})

    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("ran-with-dangling-gate\n")
  ensure
    File.delete(gate) if gate && File.symlink?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "under check mode reports changed for a creates: gate that is a dangling symlink" do
    path = sc_path("script_cm_creates_dangling.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_creates_dangling_gate")
    File.delete?(gate)
    File.symlink("/nonexistent-activepython", gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["skipped"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(gate) if gate && File.symlink?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "skips a removes: gate pointing at a dangling symlink" do
    path = sc_path("script_removes_dangling.sh")
    File.write(path, "#!/bin/sh\necho should-not-run\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_removes_dangling_gate")
    File.delete?(gate)
    File.symlink("/nonexistent-activepython", gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "removes" => gate})

    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("#{gate} does not exist, matching removes option")
  ensure
    File.delete(gate) if gate && File.symlink?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  # The warm half of hesidoryn.python-coreos (#1641): the cold bootstrap
  # left /opt/bin/python as a dangling symlink and its script still exits
  # non-zero (the ActivePython download 404s), so Ansible re-runs the
  # script and reports the task FAILED - the play exits 2. A gate that
  # matched the link itself answered "exists", skipped the task and let
  # the play exit 0, which is the exit-code half of that divergence.
  it "runs a creates: dangling-symlink gate whose script exits non-zero" do
    path = sc_path("script_creates_dangling_failing.sh")
    File.write(path, "#!/bin/sh\necho bootstrap-failed >&2\nexit 1\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_creates_dangling_failing_gate")
    File.delete?(gate)
    File.symlink("/nonexistent-activepython", gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate})

    falsey?(result["skipped"]?).must_equal(true)
    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i.must_equal(1)
  ensure
    File.delete(gate) if gate && File.symlink?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  # `test -e` is a literal-path check - unlike command:'s glob.glob gate,
  # a creates: value carrying glob metacharacters is never expanded, so a
  # file matching the pattern does NOT hold the gate.
  it "does not glob a creates: gate pattern" do
    path = sc_path("script_creates_glob.sh")
    File.write(path, "#!/bin/sh\necho ran-despite-matching-file\n")
    File.chmod(path, 0o755)
    File.write(sc_path("script_creates_glob_marker.conf"), "matches the pattern")
    gate = sc_path("script_creates_glob_*.conf")

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate})

    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("ran-despite-matching-file\n")
  ensure
    File.delete(path) if path && File.exists?(path)
    File.delete(sc_path("script_creates_glob_marker.conf")) if File.exists?(sc_path("script_creates_glob_marker.conf"))
  end

  # `~` is not expanduser'd for these gates: Ansible's script action
  # never routes them through AnsibleModule, so `test -e '~'` is false
  # and the script runs even though the home directory exists.
  it "does not expand ~ in a creates: gate" do
    path = sc_path("script_creates_tilde.sh")
    File.write(path, "#!/bin/sh\necho ran-despite-tilde\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => "~"})

    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("ran-despite-tilde\n")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "runs with executable: as an explicit interpreter" do
    path = sc_path("script_interp.py")
    File.write(path, "print('via-interpreter')\n")

    result = PluginSpecHelper.run("script", {"cmd" => path, "executable" => "/usr/bin/env python3"})

    result["stdout"].as_s.must_equal("via-interpreter\n")
  end

  it "skips without running the script under _ansible_check_mode" do
    # Ansible's script module does not support check mode: under
    # --check the task reports `skipping:` and the script never runs
    # (found via the dirless-infra findings - krikri executed the
    # script for real under --check).
    path = sc_path("script_check_mode.sh")
    File.write(path, "#!/bin/sh\ntouch #{sc_path("script_check_mode_marker")}\n")
    File.chmod(path, 0o755)
    marker = sc_path("script_check_mode_marker")
    File.delete?(marker)

    result = PluginSpecHelper.run("script", {"cmd" => path, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Check mode is not supported for this task.")
    File.exists?(marker).must_equal(false)
  ensure
    File.delete(marker) if marker && File.exists?(marker)
    File.delete(path) if path && File.exists?(path)
  end

  # Ansible's script action plugin supports check mode PARTIALLY,
  # via creates:/removes: gates (live-verified against ansible-core
  # 2.19.4): a holding gate reports `skipping:` with the "matching
  # creates/removes option" msg, a passing gate reports an ordinary
  # changed: true would-have-run result - and in NEITHER gated case
  # does the script itself execute under --check.
  it "under check mode with a HOLDING creates: gate reports skipping" do
    path = sc_path("script_cm_creates_hold.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_creates_gate")
    File.write(gate, "exists")

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("#{gate} exists, matching creates option")
  ensure
    File.delete(gate) if gate && File.exists?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "under check mode with a PASSING creates: gate reports changed:true without running" do
    path = sc_path("script_cm_creates_pass.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_creates_absent_gate")
    File.delete?(gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "creates" => gate, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["skipped"]?.try(&.as_bool)).must_equal(true)
    File.exists?(gate).must_equal(false)
  ensure
    File.delete(gate) if gate && File.exists?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "under check mode with a HOLDING removes: gate reports skipping" do
    path = sc_path("script_cm_removes_hold.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_removes_absent_gate")
    File.delete?(gate)

    result = PluginSpecHelper.run("script", {"cmd" => path, "removes" => gate, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("#{gate} does not exist, matching removes option")
  ensure
    File.delete(gate) if gate && File.exists?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "under check mode with a PASSING removes: gate reports changed:true without running" do
    path = sc_path("script_cm_removes_pass.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_removes_gate")
    File.write(gate, "exists")

    result = PluginSpecHelper.run("script", {"cmd" => path, "removes" => gate, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["skipped"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(gate) if gate && File.exists?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "runs from _raw_params alone (free-form/bare-string form)" do
    path = sc_path("script_raw_params.sh")
    File.write(path, "#!/bin/sh\necho from-raw-params\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"_raw_params" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.must_equal("from-raw-params\n")
  end

  # Real's script ACTION plugin validates chdir controller-side, BEFORE its
  # check-mode branch (live-verified against ansible-core 2.21.6): a relative
  # chdir fails the task even under --check, where this plugin's old flow
  # answered the plain unsupported-mode skip (found by krikri-playbook-
  # generator, playbook 000025-multi-script-chaos: `chdir: 78`).
  it "under check mode fails a non-absolute chdir instead of skipping" do
    path = sc_path("script_cm_chdir_rel.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path, "chdir" => "78", "_ansible_check_mode" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chdir 78 must be an absolute path for a Unix-aware remote node")
    result["_ansible_action_level"].as_bool.must_equal(true)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # Real validates chdir AFTER the creates:/removes: gates, so a holding gate
  # still skips a task with an invalid chdir (both modes).
  it "skips a HOLDING creates: gate before the chdir validation under check mode" do
    path = sc_path("script_cm_chdir_gate.sh")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
    gate = sc_path("script_cm_chdir_gate_marker")
    File.write(gate, "exists")

    result = PluginSpecHelper.run("script", {"cmd" => path, "chdir" => "78", "creates" => gate, "_ansible_check_mode" => "true"})

    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("#{gate} exists, matching creates option")
  ensure
    File.delete(gate) if gate && File.exists?(gate)
    File.delete(path) if path && File.exists?(path)
  end

  it "fails with the required_one_of message when neither cmd: nor _raw_params: is given" do
    result = PluginSpecHelper.run("script", {"chdir" => sc_path("raw-params-cwd")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("one of the following is required: _raw_params, cmd")
  end

  it "fails with the mutually_exclusive message when both cmd: and _raw_params: are given" do
    path = sc_path("script_both.sh")
    File.write(path, "#!/bin/sh\necho should-never-run\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path, "_raw_params" => path})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: _raw_params|cmd")
  end

  # Issue #1160 (kpg 000025-multi-script-chaos): real's script ACTION
  # rejects a non-absolute chdir with an AnsibleActionFail BEFORE the
  # transfer/run - changed: false with the action's own message, never
  # the remote shell's "cd: No such file or directory" non-zero rc.
  it "fails a relative chdir with the action's absolute-path message instead of running" do
    path = sc_path("script_chdir_relative.sh")
    File.write(path, "#!/bin/sh\necho should-never-run\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path, "chdir" => "78"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("chdir 78 must be an absolute path for a Unix-aware remote node")
    # No rc/stdout/stderr: the script action failed before any execution.
    falsey?(result["rc"]?).must_equal(true)
    falsey?(result["stdout"]?).must_equal(true)
    # The controller-side raise marker the display and the until:/retries:
    # escape route on - without it the failure renders through the generic
    # "Module failed:" chain.
    result["_ansible_action_level"].as_bool.must_equal(true)
  end

  it "fails clearly when the script path doesn't exist" do
    result = PluginSpecHelper.run("script", {"cmd" => sc_path("does-not-exist.sh")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not exist")
  end
end
