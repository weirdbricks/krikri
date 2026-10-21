require "../minitest_helper"
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
