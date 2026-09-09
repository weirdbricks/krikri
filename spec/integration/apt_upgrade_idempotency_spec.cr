require "../spec_helper"
require "file_utils"

# Regression spec for the `apt` module's `upgrade: full|dist|yes|safe`
# idempotency (0.9.868). Two related defects, both found via
# entanet_devops.common / entanet_devops.upgrade (rounds 73358+), whose
# single task is `apt: {upgrade: full, update_cache: yes, autoremove: yes}`:
#
# 1. The warm rerun always reported `changed: true` where real Ansible
#    reported `ok`. Real Ansible's apt module never reaches its own
#    cleanup() when `upgrade:` is set - upgrade() exits the module - and
#    folds the autoremove intent into the upgrade command itself
#    (`dist-upgrade --auto-remove`). This plugin instead ran a standalone
#    `apt-get -y autoremove` BEFORE the upgrade, so leftovers created by
#    the cold dist-upgrade (canonical case: a new kernel ABI obsoletes
#    the previous kernel) were only removed by the WARM run's autoremove,
#    reporting `changed: true` on every rerun.
#
# 2. The no-op detection (`0 upgraded, 0 newly installed, 0 to remove`)
#    omitted real Ansible's APT_GET_ZERO leading newline, so a genuine
#    "10 upgraded, 0 newly installed, 0 to remove ..." run matched the
#    zero-string at offset 1 and falsely reported a no-op.

# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS and answers `dist-upgrade`/`upgrade` with the canned
# summary in $KRIKRI_APT_UPGRADE_OUT (exit 0); `stat` reports a static
# mtime so the cache-update probe never sees movement. Yields the
# `_environment` JSON param and the call-log path.
private def with_upgrade_shim(upgrade_output : String, &)
  dir = File.join(Dir.tempdir, "krikri-apt-upgrade-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    case "$*" in
      *dist-upgrade*|*" upgrade "*)
        printf '%b' "$KRIKRI_APT_UPGRADE_OUT"
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log, "KRIKRI_APT_UPGRADE_OUT" => upgrade_output}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def zero_upgrade_output : String
  "Reading package lists...\nBuilding dependency tree...\nReading state information...\nCalculating upgrade...\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n"
end

describe "apt plugin upgrade: idempotency" do
  it "reports changed: false when the upgrade is a genuine no-op (0 upgraded) and does not run a standalone autoremove" do
    with_upgrade_shim(zero_upgrade_output) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "upgrade"      => "full",
        "update_cache" => "true",
        "autoremove"   => "true",
        "_environment" => env,
      })

      result["changed"].as_bool.should be_false
      calls = File.read(log)
      calls.should contain("dist-upgrade --auto-remove")
      calls.should_not contain("autoremove")
    end
  end

  it "reports changed: true when the upgrade output shows packages were upgraded (even a count ending in 0)" do
    with_upgrade_shim("Reading package lists...\nCalculating upgrade...\nThe following packages will be upgraded:\n  libc6\n10 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n") do |env, _log|
      result = PluginSpecHelper.run("apt", {
        "upgrade"      => "full",
        "update_cache" => "true",
        "_environment" => env,
      })

      result["changed"].as_bool.should be_true
    end
  end

  it "reports changed: false for upgrade: dist on a no-op run" do
    with_upgrade_shim(zero_upgrade_output) do |env, _log|
      result = PluginSpecHelper.run("apt", {
        "upgrade"      => "dist",
        "update_cache" => "true",
        "_environment" => env,
      })

      result["changed"].as_bool.should be_false
    end
  end

  it "reports changed: false for upgrade: yes on a no-op run and uses --with-new-pkgs" do
    with_upgrade_shim(zero_upgrade_output) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "upgrade"      => "yes",
        "update_cache" => "true",
        "_environment" => env,
      })

      result["changed"].as_bool.should be_false
      File.read(log).should contain("upgrade --with-new-pkgs")
    end
  end
end
