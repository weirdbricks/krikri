require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the service module's remaining
# real-Ansible options: arguments, pattern, sleep (plus runlevel's
# under-systemd ignore, which the action plugin lumps in with them).
#
# All three are documented `service:` options, but on a systemd-managed
# host real Ansible's service ACTION plugin
# (ansible/plugins/action/service.py, UNUSED_PARAMS['systemd']) strips
# each one that was given and warns `Ignoring "<param>" as it is not
# used in "systemd"` before the systemd module ever sees it.
# Live-verified against ansible-core 2.19.4 on this systemd machine:
#   service: {name: cron, state: started, arguments: "--test-arg",
#             sleep: 5, pattern: "cron"}
# succeeds normally and carries all three warnings in the fixed
# pattern/runlevel/sleep/arguments order.
#
# The plugin talks to the host only through #remote_exec, so every
# example here runs against REAL shim binaries (a fake systemctl /
# service / rc-service first on PATH via the plugin's `_environment`
# seam, as the apt param-coverage spec does) and asserts on the
# argument lines those shims log - the systemd no-op behavior, the
# exact warning texts, and the SysV/OpenRC command construction are
# genuinely executed, not shape-matched. The SysV examples need an init
# script to exist for the requested name (the plugin's fail_if_missing
# probes the real /etc/init.d) and guard on /etc/init.d/cron, which
# every Debian-family machine this suite runs on has.

# Writes shim `systemctl`/`service`/`rc-service` binaries that log one
# line per invocation ("$@", arguments only) and yields the
# `_environment` blob plus the log path. The shim dir comes first on
# PATH, ahead of the plugin's own extra bin dirs, so detection and
# dispatch both pick the shims up.
private def with_service_shims(load_state : String, active_state : String, &)
  dir = File.join(Dir.tempdir, "krikri-service-param-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, "systemctl"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVC_CALLS"
    case "$1" in
      show)
        printf 'LoadState=%s\nActiveState=%s\n' "$KRIKRI_LOAD_STATE" "$KRIKRI_ACTIVE_STATE"
        ;;
      *)
        exit 0
        ;;
    esac
  SHIM

  File.write(File.join(dir, "service"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVC_CALLS"
    exit 0
  SHIM

  # The engine implements real Ansible's in-process restart sleep as a
  # `sleep N` shellout, so a shim makes it observable in the same log
  # (and keeps the spec fast - no real sleeping).
  File.write(File.join(dir, "sleep"), <<-'SHIM')
    #!/bin/sh
    echo "sleep $@" >> "$KRIKRI_SVC_CALLS"
  SHIM

  File.write(File.join(dir, "rc-service"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVC_CALLS"
    case "$1" in
      status) echo " * status: started" ;;
    esac
    exit 0
  SHIM

  %w[systemctl service rc-service sleep].each do |shim|
    File.chmod(File.join(dir, shim), 0o755)
  end

  env = {
    "PATH"                => "#{dir}:/usr/bin:/bin",
    "KRIKRI_SVC_CALLS"    => log,
    "KRIKRI_LOAD_STATE"   => load_state,
    "KRIKRI_ACTIVE_STATE" => active_state,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def read_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

SYSTEMD_PATTERN_WARNING   = "Ignoring \"pattern\" as it is not used in \"systemd\""
SYSTEMD_SLEEP_WARNING     = "Ignoring \"sleep\" as it is not used in \"systemd\""
SYSTEMD_ARGUMENTS_WARNING = "Ignoring \"arguments\" as it is not used in \"systemd\""

describe "service plugin - parameter coverage" do
  describe "systemd-managed host (real Ansible's UNUSED_PARAMS behavior)" do
    it "accepts arguments:/pattern:/sleep:, changes nothing, and emits real Ansible's exact warnings" do
      with_service_shims("loaded", "active") do |env, log|
        result = PluginSpecHelper.run("service", {
          "name"         => "krikri-fake-svc",
          "state"        => "started",
          "arguments"    => "--test-arg",
          "sleep"        => "5",
          "pattern"      => "krikri",
          "use"          => "systemd",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_false
        result["changed"].as_bool.should be_false
        warnings = result["warnings"].as_a.map(&.as_s)
        warnings.should eq([
          SYSTEMD_PATTERN_WARNING,
          SYSTEMD_SLEEP_WARNING,
          SYSTEMD_ARGUMENTS_WARNING,
        ])

        # The params never reach systemctl: the only invocation is the
        # status probe, with none of the given values anywhere in it.
        calls = read_calls(log)
        calls.size.should eq(1)
        calls.first.should start_with("show krikri-fake-svc")
        calls.join("\n").should_not contain("--test-arg")
      end
    end

    it "carries the warnings on a failure result too, like real Ansible's action plugin ordering" do
      with_service_shims("not-found", "inactive") do |env, _log|
        result = PluginSpecHelper.run("service", {
          "name"         => "krikri-nope-svc",
          "state"        => "started",
          "sleep"        => "5",
          "use"          => "systemd",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("Could not find the requested service krikri-nope-svc: host")
        result["warnings"].as_a.map(&.as_s).should eq([SYSTEMD_SLEEP_WARNING])
      end
    end

    it "emits no warning when none of the systemd-unused params are given" do
      with_service_shims("loaded", "active") do |env, _log|
        result = PluginSpecHelper.run("service", {
          "name"         => "krikri-fake-svc",
          "state"        => "started",
          "use"          => "systemd",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_false
        result.as_h.has_key?("warnings").should be_false
      end
    end
  end

  describe "non-systemd managers (real Ansible gives the params real effect there)" do
    it "does not emit the systemd warnings when use: sysvinit is pinned" do
      next unless File.exists?("/etc/init.d/cron")
      with_service_shims("loaded", "active") do |env, _log|
        result = PluginSpecHelper.run("service", {
          "name"         => "cron",
          "state"        => "started",
          "use"          => "sysvinit",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_false
        result.as_h.has_key?("warnings").should be_false
      end
    end

    it "appends arguments: to the SysV command and sleeps between a restart's stop and start" do
      next unless File.exists?("/etc/init.d/cron")
      with_service_shims("loaded", "active") do |env, log|
        result = PluginSpecHelper.run("service", {
          "name"         => "cron",
          "state"        => "restarted",
          "arguments"    => "--my-flag",
          "sleep"        => "2",
          "use"          => "sysvinit",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_false
        calls = read_calls(log)
        stop = calls.index("cron stop --my-flag")
        nap = calls.index("sleep 2")
        start = calls.index("cron start --my-flag")
        stop.should_not be_nil
        nap.should_not be_nil
        start.should_not be_nil
        stop.not_nil!.should be < nap.not_nil!
        nap.not_nil!.should be < start.not_nil!
      end
    end

    it "appends arguments: to the OpenRC command form" do
      with_service_shims("loaded", "active") do |env, log|
        result = PluginSpecHelper.run("service", {
          "name"         => "krikri-fake-svc",
          "state"        => "restarted",
          "arguments"    => "--my-flag",
          "use"          => "openrc",
          "_environment" => env,
        })

        result["failed"].as_bool.should be_false
        calls = read_calls(log)
        calls.should contain("krikri-fake-svc restart --my-flag")
        # No sleep call: real Ansible's OpenRC restart is native, no
        # stop-then-start split to sleep between.
        calls.join("\n").should_not contain("sleep ")
      end
    end
  end
end
