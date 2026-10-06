require "../minitest_helper"
require "file_utils"

# `package: {name: "*", state: latest}` on an apt host. Ansible's apt.py
# (the backend `package:` delegates to) has its own
# `if latest and all_installed:` branch that runs upgrade(module, 'yes',
# ...) - the same command `upgrade: yes` builds - and never a
# per-package `apt-get install *`: apt-get treats a bare `*` as a glob
# over EVERY package in the archive, so on a host with a held/conflicting
# package pair it drags in packages a real `apt-get upgrade` never
# touches and fails with "E: Unable to correct problems, you have held
# broken packages" where Ansible reports a clean upgrade (found via
# MindPointGroup.ubuntu22_cis's "1.2.2.1 | PATCH | Ensure updates, patches
# and additional security software are installed" task, round 1500409).
#
# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS, prints $KRIKRI_APT_UPGRADE_OUT and exits with
# $KRIKRI_APT_EXIT - so the whole dispatch is side-effect-free and the
# asserted command line is exactly what got run. Yields the
# `_environment` JSON param and the call-log path.
private def with_wildcard_shim(upgrade_output : String, exit_code : Int32 = 0, &)
  dir = File.join(Dir.tempdir, "krikri-pkg-wildcard-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    if [ "${KRIKRI_APT_EXIT:-0}" != "0" ]; then
      printf '%b' "$KRIKRI_APT_UPGRADE_OUT" >&2
    else
      printf '%b' "$KRIKRI_APT_UPGRADE_OUT"
    fi
    exit "${KRIKRI_APT_EXIT:-0}"
    SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.chmod(File.join(dir, "apt-get"), 0o755)
  env = {
    "PATH"                => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_CALLS"    => log,
    "KRIKRI_APT_UPGRADE_OUT" => upgrade_output,
    "KRIKRI_APT_EXIT"     => exit_code.to_s,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def wildcard_zero_output : String
  "Reading package lists...\nBuilding dependency tree...\nReading state information...\nCalculating upgrade...\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n"
end

describe "package plugin name:* state: latest" do
  it "runs apt-get upgrade --with-new-pkgs, never apt-get install '*'" do
    with_wildcard_shim(wildcard_zero_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      calls = File.read(log)
      calls.must_include("upgrade --with-new-pkgs")
      calls.wont_include(" install ")
      # A genuine no-op upgrade reports changed: false (apt.py's
      # APT_GET_ZERO exit).
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "reports changed: true when the upgrade output shows upgraded packages" do
    output = "Reading package lists...\nCalculating upgrade...\nThe following packages will be upgraded:\n  libc6\n2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n"
    with_wildcard_shim(output) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
    end
  end

  it "fails with apt.py's own '<cmd> failed: <err>' message on a non-zero rc" do
    with_wildcard_shim("E: Unable to correct problems, you have held broken packages.\n", 100) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/upgrade --with-new-pkgs.*' failed: E: Unable to correct problems/)
      result["rc"].as_i.must_equal(100)
    end
  end

  it "refuses to mix '*' with real package names, like apt.py's own fail_json" do
    with_wildcard_shim(wildcard_zero_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "[\"*\", \"bash\"]",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("unable to install additional packages when upgrading all installed packages")
      # Nothing ran at all - the refusal precedes every apt-get call.
      File.exists?(log).must_equal(false)
    end
  end
end
