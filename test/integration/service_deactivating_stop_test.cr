require "../minitest_helper"
require "file_utils"

# Regression spec for issue #378 (Frzk.chrony, round29883883): the role's
# "Disable conflicting services" loop reported changed for `ntp` under
# ansible-playbook and ok under krikri-playbook on a pair of identical
# fresh Ubuntu hosts, because Ansible caught the unit mid-stop -
# ActiveState=deactivating - and krikri read that as already stopped.
#
# Ansible's systemd module only treats such a unit as needing action in its
# `stopped` branch (`is_running_service(status) or
# is_deactivating_service(status)`, systemd_service.py), while every other
# requested state looks at active|activating alone. Verified live against
# ansible-core 2.19.11 on a systemd host with a systemctl shim that reports
# ActiveState=deactivating: ansible stopped the unit and printed changed.

# A `systemctl` shim that reports the given LoadState/ActiveState for the
# single status probe and logs every invocation, so the decision and the
# command it produced are both observable. The shim dir goes first on PATH,
# ahead of the plugin's extra bin dirs, so detection and dispatch use it.
private def with_active_state_shims(load_state : String, active_state : String, &)
  dir = File.join(Dir.tempdir, "krikri-service-deactivating-#{Random.rand(1_000_000)}")
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

  File.chmod(File.join(dir, "systemctl"), 0o755)

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

private def read_svc_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

private def run_service(state : String, env : String)
  PluginSpecHelper.run("service", {
    "name"         => "krikri-fake-svc",
    "state"        => state,
    "use"          => "systemd",
    "_environment" => env,
  })
end

describe "service plugin - systemd unit still deactivating" do
  it "stops a deactivating unit and reports changed, like Ansible's stopped branch" do
    with_active_state_shims("loaded", "deactivating") do |env, log|
      result = run_service("stopped", env)

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      read_svc_calls(log).includes?("stop krikri-fake-svc").must_equal(true)
    end
  end

  it "still starts a deactivating unit for state: started (active|activating only)" do
    with_active_state_shims("loaded", "deactivating") do |env, log|
      result = run_service("started", env)

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      calls = read_svc_calls(log)
      calls.includes?("start krikri-fake-svc").must_equal(true)
      calls.includes?("stop krikri-fake-svc").must_equal(false)
    end
  end

  it "starts rather than reloads a deactivating unit, like Ansible's else branch" do
    with_active_state_shims("loaded", "deactivating") do |env, log|
      result = run_service("reloaded", env)

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      calls = read_svc_calls(log)
      calls.includes?("start krikri-fake-svc").must_equal(true)
      calls.includes?("reload krikri-fake-svc").must_equal(false)
    end
  end

  it "reports no change for an already inactive unit with state: stopped" do
    with_active_state_shims("loaded", "inactive") do |env, log|
      result = run_service("stopped", env)

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      read_svc_calls(log).includes?("stop krikri-fake-svc").must_equal(false)
    end
  end
end
