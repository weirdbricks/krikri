require "../minitest_helper"
require "../../src/krikri/plugin_helpers/apt_lock_retry"
require "file_utils"

# Regression spec for round 1100002 (atlantic_local kop_apt_fail), three
# ansible.builtin.apt key-order/behavior divergences against ansible-core
# 2.19.11 on Ubuntu 22.04:
#
#   1. apt_fail_deb        - a failed `deb:` carried a spurious
#                            cache_updated: false (real install_deb exits
#                            through its own fail_json/exit_json before
#                            main() assigns the cache keys).
#   2. apt_fixed           - `state: fixed` with no name omitted
#                            cache_update_time (real install()'s empty-spec
#                            retvals gain both cache keys from main()).
#   3. apt_fail_bogus_source - `update_cache: true` against a bogus source
#                            reported success where Ansible fails after its
#                            FetchFailedException retry loop. Root cause:
#                            python-apt's Cache.update() raises a BARE
#                            FetchFailedException() when any acquire item
#                            fails, while the CLI `apt-get update` this
#                            plugin shells out to treats the same partial
#                            failure as warning-level and exits 0 (verified
#                            in a jammy container with this exact bogus
#                            entry, even as the only configured source).
#                            python-apt's bare exception is also why the
#                            real capture's reason is EMPTY ("due to ,
#                            retrying" / "...after 5 retries: ").
#
# The retry loop itself is tested through the AptLockRetry module seam
# (same pattern as apt_lock_retry_test.cr - no plugin entry point fires);
# the plugin wiring is tested through the real plugin binary with a fake
# `apt-get` shim on PATH (same pattern as dnf_backend_key_order_test.cr).

# Canned jammy `apt-get update` output for one unresolvable bogus source:
# exit 0, W:-level only on stderr, per-item Err: lines on stdout.
APT_UPDATE_FETCH_FAILED = {
  exit_code: 0,
  stdout:    "Err:1 https://kop-bogus.invalid/apt jammy InRelease\n  Could not resolve 'kop-bogus.invalid'\nFetched 0 B in 0s (0 B/s)\nReading package lists...\n",
  stderr:    "W: Failed to fetch https://kop-bogus.invalid/apt/dists/jammy/InRelease  Could not resolve 'kop-bogus.invalid'\nW: Some index files failed to download. They have been ignored, or old ones used instead.\n",
}
APT_UPDATE_FETCH_CLEAN = {exit_code: 0, stdout: "Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease\n", stderr: ""}

# StubExec already exists in apt_lock_retry_test.cr's compilation unit;
# this spec is also runnable standalone, so it carries its own copy under
# a unique name.
class FetchFailedStubExec
  getter exec_count : Int32 = 0
  @responses : Array(NamedTuple(exit_code: Int32, stdout: String, stderr: String))
  @idx : Int32 = 0

  def initialize(@responses)
  end

  def call(cmd : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
    @exec_count += 1
    resp = @responses[@idx]? || @responses.last
    @idx += 1 unless @idx >= @responses.size - 1
    resp
  end
end

class FetchFailedHostClass
  include Krikri::AptLockRetry
end

describe "apt fetch-failure detection and FetchFailedException retry loop (round 1100002)" do
  describe "#apt_fetch_failed?" do
    it "detects the jammy exit-0 W:-only partial-fetch failure" do
      FetchFailedHostClass.new.apt_fetch_failed?(APT_UPDATE_FETCH_FAILED).must_equal(true)
    end

    it "returns false for a clean successful update" do
      FetchFailedHostClass.new.apt_fetch_failed?(APT_UPDATE_FETCH_CLEAN).must_equal(false)
    end

    it "returns false for empty output" do
      FetchFailedHostClass.new.apt_fetch_failed?({exit_code: 0, stdout: "", stderr: ""}).must_equal(false)
    end

    it "returns false for a nonzero lock-contention failure without fetch markers" do
      lock = {exit_code: 100, stdout: "", stderr: "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1738 (unattended-upgr)\n"}
      FetchFailedHostClass.new.apt_fetch_failed?(lock).must_equal(false)
    end
  end

  describe "#apt_fetch_failed_update_retry" do
    it "stays unrecovered and emits one warn pair per failed attempt" do
      stub = FetchFailedStubExec.new([APT_UPDATE_FETCH_FAILED])
      outcome = FetchFailedHostClass.new.apt_fetch_failed_update_retry(2, 1, ->(c : String) { stub.call(c) })
      outcome[:recovered].must_equal(false)
      outcome[:warnings].size.must_equal(4)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to , retrying")
      outcome[:warnings][1].matches?(/^Sleeping for [12] seconds, before attempting to refresh the cache again$/).must_equal(true)
      outcome[:warnings][2].must_equal("Failed to update cache after 2 retries due to , retrying")
      outcome[:warnings][3].matches?(/^Sleeping for [12] seconds, before attempting to refresh the cache again$/).must_equal(true)
      stub.exec_count.must_equal(2)
    end

    it "recovers (keeping the warn pairs so far) when a retry attempt succeeds" do
      # The caller's initial attempt already failed before the helper is
      # entered, so stub call 1 is retry attempt 1: it fails (warn pair
      # for it is emitted after that failure, before attempt 2), and
      # attempt 2 succeeds - two warn pairs total, no pair for the
      # attempt that never failed.
      stub = FetchFailedStubExec.new([APT_UPDATE_FETCH_FAILED, APT_UPDATE_FETCH_CLEAN])
      outcome = FetchFailedHostClass.new.apt_fetch_failed_update_retry(5, 12, ->(c : String) { stub.call(c) })
      outcome[:recovered].must_equal(true)
      outcome[:warnings].size.must_equal(4)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to , retrying")
      outcome[:warnings][2].must_equal("Failed to update cache after 2 retries due to , retrying")
      stub.exec_count.must_equal(2)
    end

    it "fails immediately with no warnings when update_cache_retries is 0" do
      stub = FetchFailedStubExec.new([APT_UPDATE_FETCH_FAILED])
      outcome = FetchFailedHostClass.new.apt_fetch_failed_update_retry(0, 12, ->(c : String) { stub.call(c) })
      outcome[:recovered].must_equal(false)
      outcome[:warnings].must_equal([] of String)
      stub.exec_count.must_equal(0)
    end
  end
end

# Plugin-level wiring, driven through the real plugin binary.
describe "apt plugin round-1100002 result shapes" do
  serial!

  it "omits cache_updated on a failed deb: (apt_fail_deb key order)" do
    result = PluginSpecHelper.run("apt", {"deb" => "/var/tmp/kop-nonexistent-keyorder.deb", "state" => "present"})

    result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unable to install package: E:Could not open file /var/tmp/kop-nonexistent-keyorder.deb - open (2: No such file or directory)")
    result["changed"].as_bool.must_equal(false)
  end

  it "carries cache_update_time on a no-name state=fixed ok (apt_fixed key order)" do
    result = PluginSpecHelper.run("apt", {"state" => "fixed"})

    result.as_h.keys.must_equal(["changed", "cache_updated", "cache_update_time"])
    result["changed"].as_bool.must_equal(false)
    result["cache_updated"].as_bool.must_equal(false)
    expected_mtime = `stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0`.strip.to_i
    result["cache_update_time"].as_i.must_equal(expected_mtime)
  end

  it "keeps the no-name state=absent ok bare (remove() exits before main's cache keys)" do
    result = PluginSpecHelper.run("apt", {"state" => "absent"})

    result.as_h.keys.must_equal(["changed"])
    result["changed"].as_bool.must_equal(false)
  end

  it "fails update_cache with Ansible's FetchFailedException wording after the retry budget" do
    with_fake_apt_get_update do |counter|
      result = PluginSpecHelper.run("apt", {
        "update_cache"                 => "true",
        "update_cache_retries"         => "1",
        "update_cache_retry_max_delay" => "1",
      })

      result.as_h.keys.must_equal(["failed", "msg", "changed", "exception", "warnings"])
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to update apt cache after 1 retries: ")
      result["changed"].as_bool.must_equal(false)
      warnings = result["warnings"].as_a.map(&.as_s)
      warnings.size.must_equal(2)
      warnings[0].must_equal("Failed to update cache after 1 retries due to , retrying")
      warnings[1].matches?(/^Sleeping for [12] seconds, before attempting to refresh the cache again$/).must_equal(true)
      # initial attempt + one retry
      File.read(counter).strip.to_i.must_equal(2)
    end
  end

  it "reports success when a retry attempt recovers the fetch" do
    with_fake_apt_get_update(recover_after: 1) do |counter|
      result = PluginSpecHelper.run("apt", {
        "update_cache"                 => "true",
        "update_cache_retries"         => "2",
        "update_cache_retry_max_delay" => "1",
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      File.read(counter).strip.to_i.must_equal(2)
    end
  end
end

# Writes a counting fake `apt-get` that answers `apt-get update` with the
# jammy partial-fetch-failure capture for the first `fail_times` calls and
# a clean success afterwards, then runs the block with that shim first on
# PATH. Only `update` is faked - every other apt-get subcommand would be a
# real mutation this suite must never perform, so it is refused loudly.
private def with_fake_apt_get_update(recover_after : Int32 = Int32::MAX, &) : Nil
  shim_dir = PluginSpecHelper.tmp_path("fake-apt-get-update")
  counter = PluginSpecHelper.tmp_path("apt-get-update-calls")
  FileUtils.rm_r(shim_dir) if File.exists?(shim_dir)
  File.delete(counter) if File.exists?(counter)
  Dir.mkdir_p(shim_dir)
  script = <<-SH
    #!/bin/sh
    COUNT="#{counter}"
    if [ "$1" != "update" ]; then
      echo "fake apt-get shim: refusing subcommand $1" >&2
      exit 99
    fi
    n=$(cat "$COUNT" 2>/dev/null || echo 0)
    n=$((n+1))
    echo "$n" > "$COUNT"
    if [ "$n" -le #{recover_after} ]; then
      echo "Err:1 https://kop-bogus.invalid/apt jammy InRelease"
      echo "  Could not resolve 'kop-bogus.invalid'"
      echo "Fetched 0 B in 0s (0 B/s)"
      echo "Reading package lists..."
      echo "W: Failed to fetch https://kop-bogus.invalid/apt/dists/jammy/InRelease  Could not resolve 'kop-bogus.invalid'" >&2
      echo "W: Some index files failed to download. They have been ignored, or old ones used instead." >&2
      exit 0
    fi
    echo "Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease"
    exit 0
    SH
  File.write("#{shim_dir}/apt-get", script)
  File.chmod("#{shim_dir}/apt-get", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield counter
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end
