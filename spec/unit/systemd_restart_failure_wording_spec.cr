require "../spec_helper"
require "file_utils"

# Regression specs for the systemd plugin's state-change failure wording
# and verb selection, added in 0.9.x after the fix-systemd-restart
# investigation. Found live in a systemd-repro podman container (a
# Type=oneshot unit whose ExecStart fails): real Ansible's
# systemd module (ansible/modules/systemd_service.py) picks the
# state-change VERB by the unit's CURRENT state - for `state: restarted`
# on an inactive unit it runs `systemctl start`, never `restart` - and
# words every state-change failure "Unable to <action> service <name>:
# <err>". This engine used to always run `restart` and word the failure
# "Failed to restart <name>: <stderr>", so the same failing task showed a
# different message than real ansible-playbook (the failed/changed recap
# counters already agreed).
#
# The plugin talks to the host only through #remote_exec, so every
# example here runs against a shim `systemctl` first on PATH via the
# plugin's `_environment` seam (the service_param_coverage spec's
# pattern): the shim logs every invocation and answers `show` with a
# configurable ActiveState, letting the examples prove both which verb
# ran and the exact failure text without touching the real systemd.
private def with_systemd_shim(active_state : String, change_rc : Int32, &)
  dir = File.join(Dir.tempdir, "krikri-systemd-restart-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, "systemctl"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SYSTEMD_CALLS"
    case "$1" in
      show)
        # Real systemctl's `show X --property=ActiveState --value`
        # prints the bare state; the state-change verbs must be
        # observable failing with real systemctl's job-failure stderr.
        printf '%s\n' "$KRIKRI_ACTIVE_STATE"
        exit 0
        ;;
      start|stop|restart|reload)
        echo "Job for krikri-fake-svc.service failed" >&2
        exit "$KRIKRI_CHANGE_RC"
        ;;
      *)
        exit 0
        ;;
    esac
  SHIM
  File.chmod(File.join(dir, "systemctl"), 0o755)

  env = {
    "PATH"                 => "#{dir}:/usr/bin:/bin",
    "KRIKRI_SYSTEMD_CALLS" => log,
    "KRIKRI_ACTIVE_STATE"  => active_state,
    "KRIKRI_CHANGE_RC"     => change_rc.to_s,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def read_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

describe "systemd plugin - restart verb selection and failure wording" do
  it "restarted on an INACTIVE unit runs systemctl start, not restart" do
    with_systemd_shim("inactive", 1) do |env, log|
      result = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "restarted",
        "_environment" => env,
      })

      result["failed"].as_bool.should be_true
      verbs = read_calls(log).compact_map { |line| line.split(" ")[0]? }
      verbs.should contain("start")
      verbs.should_not contain("restart")
    end
  end

  it "restarted on an ACTIVE unit runs systemctl restart" do
    with_systemd_shim("active", 1) do |env, log|
      PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "restarted",
        "_environment" => env,
      })

      verbs = read_calls(log).compact_map { |line| line.split(" ")[0]? }
      verbs.should contain("restart")
      verbs.should_not contain("start")
    end
  end

  it "words a failing restart of an inactive unit like real Ansible's start action" do
    with_systemd_shim("inactive", 1) do |env, _log|
      result = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "restarted",
        "_environment" => env,
      })

      result["msg"].as_s.should eq(
        "Unable to start service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )
    end
  end

  it "words a failing restart of an active unit like real Ansible's restart action" do
    with_systemd_shim("active", 1) do |env, _log|
      result = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "restarted",
        "_environment" => env,
      })

      result["msg"].as_s.should eq(
        "Unable to restart service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )
    end
  end

  it "words started/stopped/reloaded failures the same way" do
    with_systemd_shim("inactive", 1) do |env, _log|
      started = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "started",
        "_environment" => env,
      })
      started["msg"].as_s.should eq(
        "Unable to start service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )

      reloaded = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "reloaded",
        "_environment" => env,
      })
      reloaded["msg"].as_s.should eq(
        "Unable to start service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )
    end

    with_systemd_shim("active", 1) do |env, _log|
      stopped = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "stopped",
        "_environment" => env,
      })
      stopped["msg"].as_s.should eq(
        "Unable to stop service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )

      reloaded = PluginSpecHelper.run("systemd", {
        "name"         => "krikri-fake-svc",
        "state"        => "reloaded",
        "_environment" => env,
      })
      reloaded["msg"].as_s.should eq(
        "Unable to reload service krikri-fake-svc: Job for krikri-fake-svc.service failed\n"
      )
    end
  end
end
