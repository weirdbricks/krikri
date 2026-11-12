require "../minitest_helper"
require "file_utils"

# Regression spec for issue #1157 (datadog.dd.agent): a `use: service`
# task failed on a systemd host with "Could not find the requested
# service <name>: host", while ansible-playbook ran the same task ok.
#
# `use: service` names Ansible's GENERIC service module, not the sysvinit
# one: LinuxService.get_service_tools() runs is_systemd_managed() FIRST
# and drives systemctl on a systemd host, and only falls through to the
# SysV init-script chain (which is what fail_if_missing's message came
# from) when the host is not systemd-managed. An explicit `use:` also
# beats the ansible_service_mgr fact in the action plugin.
#
# Live-verified against ansible-core 2.19.11 on this systemd host:
#   service: {name: systemd-journald, state: started, enabled: true,
#             use: service}
# succeeds and registers {name, changed, enabled, state, failed} - the
# generic module's own result, with NO status dict, NO msg, and none of
# the systemd module's `Ignoring "X" as it is not used in "systemd"`
# warnings (the generic module really consumes pattern/sleep/arguments).
private def with_use_service_shims(active_state : String, load_state : String = "loaded", &)
  dir = File.join(Dir.tempdir, "krikri-service-use-service-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, "systemctl"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVC_CALLS"
    case "$1" in
      show)
        printf 'LoadState=%s\nActiveState=%s\n' "$KRIKRI_LOAD_STATE" "$KRIKRI_ACTIVE_STATE"
        ;;
      is-enabled)
        echo enabled
        ;;
      *)
        exit 0
        ;;
    esac
  SHIM

  # Logged so a SysV dispatch is visible as a call this spec never expects.
  File.write(File.join(dir, "service"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVC_CALLS"
    exit 0
  SHIM

  %w[systemctl service].each do |shim|
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

private def read_use_service_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

describe "service plugin - use: service on a systemd host" do
  # krikri-fake-svc has no /etc/init.d script on any test host, so the
  # old SysV mapping failed here before ever probing systemd - exactly
  # the shape of the reported failure.
  it "probes systemctl and succeeds instead of failing fail_if_missing (#1157)" do
    with_use_service_shims("active") do |env, log|
      result = PluginSpecHelper.run("service", {
        "name"         => "krikri-fake-svc",
        "state"        => "started",
        "enabled"      => "true",
        "use"          => "service",
        "_environment" => env,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      calls = read_use_service_calls(log)
      calls.includes?("show krikri-fake-svc").must_equal(true)
      calls.includes?("is-enabled krikri-fake-svc").must_equal(true)
      # The SysV chain (the `service` binary / an init script) must not
      # be what answered: every recorded call belongs to systemctl.
      calls.any? { |call| call.starts_with?("krikri-fake-svc ") }.must_equal(false)
    end
  end

  it "registers the generic service module's result shape, not the systemd module's" do
    with_use_service_shims("active") do |env, _log|
      result = PluginSpecHelper.run("service", {
        "name"         => "krikri-fake-svc",
        "state"        => "started",
        "enabled"      => "true",
        "use"          => "service",
        "_environment" => env,
      })

      hash = result.as_h
      hash.has_key?("status").must_equal(false)
      hash.has_key?("msg").must_equal(false)
      result["name"].as_s.must_equal("krikri-fake-svc")
      result["enabled"].as_bool.must_equal(true)
      result["state"].as_s.must_equal("started")
    end
  end

  it "keeps the params the generic service module really uses, with no systemd warnings" do
    with_use_service_shims("active") do |env, _log|
      result = PluginSpecHelper.run("service", {
        "name"         => "krikri-fake-svc",
        "state"        => "started",
        "arguments"    => "--test-arg",
        "sleep"        => "5",
        "pattern"      => "krikri",
        "use"          => "service",
        "_environment" => env,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result.as_h.has_key?("warnings").must_equal(false)
    end
  end

  it "stays on SysV when use: sysvinit pins it, even on a systemd host" do
    skip "no /etc/init.d/cron on this host" unless File.exists?("/etc/init.d/cron")
    with_use_service_shims("active") do |env, log|
      result = PluginSpecHelper.run("service", {
        "name"         => "cron",
        "state"        => "started",
        "use"          => "sysvinit",
        "_environment" => env,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      calls = read_use_service_calls(log)
      calls.includes?("show cron").must_equal(false)
      calls.includes?("cron status").must_equal(true)
    end
  end

  # Regression spec for issue #1159: a missing unit under `use: service`
  # failed with the sysv fail_if_missing wording ("Could not find the
  # requested service X: host"), while ansible's generic service module
  # reports its own message from get_systemd_status_dict - it checks
  # `systemctl show` for LoadState=not-found and fails with
  # 'systemd could not find the requested service "%r": %s' over the
  # unit name's Python repr and that command's stderr (never
  # fail_if_missing on the systemd branch). Live-verified against
  # ansible-core 2.21.6 with exactly this unit name.
  it "fails a missing unit with the generic module's not-found wording (#1159)" do
    with_use_service_shims("inactive", load_state: "not-found") do |env, _log|
      result = PluginSpecHelper.run("service", {
        "name"         => "no-such-unit-xyz",
        "state"        => "started",
        "use"          => "service",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      # The trailing space after the colon is Ansible's too: the message
      # ends with the show command's stderr, which is empty here.
      result["msg"].as_s.must_equal(%(systemd could not find the requested service "'no-such-unit-xyz'": ))
    end
  end

  it "keeps the sysv fail_if_missing wording on the plain service: path (#1159)" do
    with_use_service_shims("inactive", load_state: "not-found") do |env, _log|
      result = PluginSpecHelper.run("service", {
        "name"         => "no-such-unit-xyz",
        "state"        => "started",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Could not find the requested service no-such-unit-xyz: host")
    end
  end
end
