require "../minitest_helper"
require "../../src/krikri/plugin_helpers/apt_lock_retry"
require "file_utils"

# Regression spec for issue #198 (galaxyproject.rabbitmq): the final
# "Failed to update apt cache after N retries: <reason>" msg of the
# apt_repository plugin. Real ansible-core 2.19.11's fallback is
# `err if err` on the caught exception OBJECT - always truthy once any
# attempt raised - so a bare FetchFailedException (str() empty) is quoted
# verbatim as an EMPTY reason, and 'unknown reason' fires only when no
# attempt ever ran (update_cache_retries <= 0). This plugin used to fall
# back on last_reason.empty? instead, which is also the bare-exception
# case. Plugin-level wiring through the real binary with a PATH-shimmed
# failing `apt-get` via `_environment` (same seam as
# test/integration/apt_repository_param_coverage_test.cr) and the
# `_sources_list`/`_sources_list_d` scratch overrides - nothing touches
# /etc/apt or the real package state. The shim's failure shape is the
# exit-0 Err:/W: partial-fetch capture (round 1100002), the CLI
# observable equivalent of python-apt's bare FetchFailedException: a
# failed attempt whose reason text is empty.
describe "apt_repository update-cache retry final msg reason" do
  it "quotes a bare fetch failure's EMPTY reason after exhausting retries >= 1" do
    dir = PluginSpecHelper.tmp_path("aptrepo-issue198-empty")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    FileUtils.mkdir_p(File.join(dir, "sources.list.d"))
    File.write(shim, <<-SHIM)
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      if [ "$1" != "update" ]; then
        echo "fake apt-get shim: refusing subcommand $1" >&2
        exit 99
      fi
      echo "Err:1 https://repo-bogus-issue198.invalid/apt jammy InRelease"
      echo "  Could not resolve 'repo-bogus-issue198.invalid'"
      echo "Fetched 0 B in 0s (0 B/s)"
      echo "Reading package lists..."
      echo "W: Failed to fetch https://repo-bogus-issue198.invalid/apt/dists/jammy/InRelease  Could not resolve 'repo-bogus-issue198.invalid'" >&2
      echo "W: Some index files failed to download. They have been ignored, or old ones used instead." >&2
      exit 0
      SHIM
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb https://packages.totally-fake-example.com/repo stable main",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => File.join(dir, "sources.list.d"),
      "update_cache"                 => "true",
      "update_cache_retries"         => "3",
      "update_cache_retry_max_delay" => "0",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to update apt cache after 3 retries: ")
    File.read_lines(log).size.must_equal(3)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Live-verified against ansible-core 2.19.11 (python-apt in-process):
  # all of the retry loop's Cache().update() calls share one process, and
  # from the second call onward a refused repo's reason carries the
  # fixed two-line W: untrusted-repo prefix, which the final
  # "Failed to update apt cache after N retries" msg quotes. The shim's
  # output is the exact refused-repo shape (GPG NO_PUBKEY warning plus
  # the "is not signed" E: line) of that live check.
  it "prefixes an unauthenticated repo's reason from the second update call onward" do
    dir = PluginSpecHelper.tmp_path("aptrepo-issue665-gpg")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    FileUtils.mkdir_p(File.join(dir, "sources.list.d"))
    File.write(shim, <<-SHIM)
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      if [ "$1" != "update" ]; then
        echo "fake apt-get shim: refusing subcommand $1" >&2
        exit 99
      fi
      echo "W: GPG error: http://127.0.0.1:8765/a ./ InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY D1D09606DE1802A4" >&2
      echo "E: The repository 'http://127.0.0.1:8765/a ./ InRelease' is not signed." >&2
      exit 0
      SHIM
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb http://127.0.0.1:8765/a ./",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => File.join(dir, "sources.list.d"),
      "update_cache"                 => "true",
      "update_cache_retries"         => "2",
      "update_cache_retry_max_delay" => "0",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    reason = "W:GPG error: http://127.0.0.1:8765/a ./ InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY D1D09606DE1802A4, E:The repository 'http://127.0.0.1:8765/a ./ InRelease' is not signed."
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to update apt cache after 2 retries: #{Krikri::AptLockRetry::APT_FETCH_SECURE_REPO_PREPEND}, #{reason}")
    File.read_lines(log).size.must_equal(2)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Issue #665 (xe0nic.ansible_vprotect_server), round 29884722's real
  # diff: the failing update's reason is the mariadb repo's tolerated
  # standalone "W: GPG error ... NO_PUBKEY ..." warning (both of the
  # role's repos are `deb [trusted=yes]`) plus the storware 404 E: lines.
  # apt never marks a repo unauthenticated for that shape, so real
  # ansible quoted the SAME unprefixed text on every attempt and in the
  # final msg - live-verified in-process on jammy 22.04 (python-apt,
  # five identical unprefixed exception texts) - while krikri 0.9.1963
  # prefixed the later attempts. The shim reproduces the exact CLI shape
  # of that live check (apt-get update prints "E: Failed to fetch" for
  # refused index downloads and exits 100).
  it "never prefixes a trusted-repo GPG-warning + 404 reason (issue #665 real-round shape)" do
    dir = PluginSpecHelper.tmp_path("aptrepo-issue665-vprotect")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    FileUtils.mkdir_p(File.join(dir, "sources.list.d"))
    File.write(shim, <<-SHIM)
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      if [ "$1" != "update" ]; then
        echo "fake apt-get shim: refusing subcommand $1" >&2
        exit 99
      fi
      echo "W: GPG error: https://mirror.rackspace.com/mariadb/mariadb-11.8.9/repo/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY F1656F24C74CD1D8" >&2
      echo "E: Failed to fetch http://repo.storware.eu/storware/current/el22/./Packages  404  Not Found [IP: 46.174.177.28 80]" >&2
      echo "E: Some index files failed to download. They have been ignored, or old ones used instead." >&2
      exit 100
      SHIM
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb http://repo.storware.eu/storware/current/el22/ ./",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => File.join(dir, "sources.list.d"),
      "update_cache"                 => "true",
      "update_cache_retries"         => "2",
      "update_cache_retry_max_delay" => "0",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    reason = "W:GPG error: https://mirror.rackspace.com/mariadb/mariadb-11.8.9/repo/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY F1656F24C74CD1D8, E:Failed to fetch http://repo.storware.eu/storware/current/el22/./Packages  404  Not Found [IP: 46.174.177.28 80], E:Some index files failed to download. They have been ignored, or old ones used instead."
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to update apt cache after 2 retries: #{reason}")
    warnings = result["warnings"].as_a.map(&.as_s)
    warnings[0].must_equal("Failed to update cache after 1 due to #{reason} retry, retrying")
    warnings[2].must_equal("Failed to update cache after 2 due to #{reason} retry, retrying")
    File.read_lines(log).size.must_equal(2)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "says 'unknown reason' only when no attempt ran (update_cache_retries 0)" do
    dir = PluginSpecHelper.tmp_path("aptrepo-issue198-zero")
    log = File.join(dir, "apt-calls.log")
    shim = File.join(dir, "apt-get")
    FileUtils.mkdir_p(File.join(dir, "sources.list.d"))
    File.write(shim, <<-SHIM)
      #!/bin/sh
      echo "$@" >> "$KRIKRI_APTREPO_CALLS"
      exit 1
      SHIM
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                         => "deb https://packages.totally-fake-example.com/repo stable main",
      "_sources_list"                => File.join(dir, "sources.list"),
      "_sources_list_d"              => File.join(dir, "sources.list.d"),
      "update_cache"                 => "true",
      "update_cache_retries"         => "0",
      "update_cache_retry_max_delay" => "0",
      "_environment"                 => {
        "PATH"                 => "#{dir}:/usr/bin:/bin",
        "KRIKRI_APTREPO_CALLS" => log,
      }.to_json,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to update apt cache after 0 retries: unknown reason")
    # The retry loop never ran, so apt-get was never invoked.
    File.exists?(log).must_equal(false)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
