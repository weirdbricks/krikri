require "../spec_helper"
require "file_utils"

# Parameter-coverage pass for `apt_repository:`'s remaining real-Ansible
# options: update_cache_retries / update_cache_retry_max_delay (wired
# for real - see PluginHelpers::AptRepositoryCacheRetry, whose unit
# spec pins the backoff formula against real ansible-core's own
# apt_repository.py) and the two documented no-ops install_python_apt /
# validate_certs (krikri never imports python-apt and always verifies
# TLS on its one HTTPS fetch, so both are accepted-and-ignored - but
# they MUST be accepted, since real playbooks pass them).
#
# The retry end-to-end runs against a scratch directory via the plugin's
# `_sources_list`/`_sources_list_d` internal overrides (same
# underscore-prefixed spec-seam family as apt.cr's `_policy_rc_d_path`)
# and a PATH-shimmed failing `apt-get` via `environment:` - nothing here
# touches /etc/apt or the real package state.

private def param_shim_dir(name : String) : String
  dir = File.join(Dir.tempdir, "krikri-aptrepo-param-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  dir
end

describe "apt_repository plugin - parameter coverage (update_cache_retries/install_python_apt/validate_certs)" do
  it "accepts install_python_apt and validate_certs without error (documented no-ops here)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"               => "deb https://packages.totally-fake-example.com/repo stable main",
      "check_mode"         => "true",
      "install_python_apt" => "false",
      "validate_certs"     => "false",
      # defaults (true) exercised implicitly by every other spec here
      "update_cache_retries"         => "5",
      "update_cache_retry_max_delay" => "12",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
  end

  it "retries a failing apt-get update up to update_cache_retries total attempts, then fails and rolls back" do
    dir = param_shim_dir("retry-exhausted")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    File.write(shim, <<-'SHIM')
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      echo "E: Krikri simulated fetch failure." >&2
      exit 100
      SHIM
    File.chmod(shim, 0o755)

    list_d = File.join(dir, "sources.list.d")
    FileUtils.mkdir_p(list_d)
    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb https://packages.totally-fake-example.com/repo stable main",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => list_d,
      "update_cache"                 => "true",
      "update_cache_retries"         => "3",
      "update_cache_retry_max_delay" => "1",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to update apt cache")
    File.read_lines(log).size.should eq(3)
    # Real Ansible reverts the just-written line when the cache update
    # exhausts its retries - the scratch sources dir must be back to
    # how it started (empty).
    Dir.glob(File.join(list_d, "*.list")).should be_empty
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "stops retrying once apt-get update succeeds and leaves the repo line in place" do
    dir = param_shim_dir("retry-recovers")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    File.write(shim, <<-'SHIM')
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      if [ "$(cat "$KRIKRI_APTREPO_CALLS" | wc -l)" -le 2 ]; then
        echo "E: Krikri simulated fetch failure." >&2
        exit 100
      fi
      exit 0
      SHIM
    File.chmod(shim, 0o755)

    list_d = File.join(dir, "sources.list.d")
    FileUtils.mkdir_p(list_d)
    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb https://packages.totally-fake-example.com/repo stable main",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => list_d,
      "update_cache"                 => "true",
      "update_cache_retries"         => "5",
      "update_cache_retry_max_delay" => "0",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read_lines(log).size.should eq(3)
    Dir.glob(File.join(list_d, "*.list")).should_not be_empty
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
