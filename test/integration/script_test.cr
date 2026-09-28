require "../minitest_helper"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def sc_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "script plugin" do
  it "executes a script and captures its stdout" do
    path = sc_path("script_echo.sh")
    File.write(path, "#!/bin/sh\necho hello-from-script\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_equal("hello-from-script")
    result["rc"].as_i.must_equal(0)
  end

  it "passes trailing arguments through to the script" do
    path = sc_path("script_args.sh")
    File.write(path, "#!/bin/sh\necho \"got: $1 $2\"\n")
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("script", {"cmd" => "#{path} one two"})

    result["stdout"].as_s.must_equal("got: one two")
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

  it "runs with executable: as an explicit interpreter" do
    path = sc_path("script_interp.py")
    File.write(path, "print('via-interpreter')\n")

    result = PluginSpecHelper.run("script", {"cmd" => path, "executable" => "/usr/bin/env python3"})

    result["stdout"].as_s.must_equal("via-interpreter")
  end

  it "skips without running the script under _ansible_check_mode" do
    # Real Ansible's script module does not support check mode: under
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

  # Real Ansible's script action plugin supports check mode PARTIALLY,
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
    result["stdout"].as_s.must_equal("from-raw-params")
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

  it "fails clearly when the script path doesn't exist" do
    result = PluginSpecHelper.run("script", {"cmd" => sc_path("does-not-exist.sh")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not exist")
  end
end
