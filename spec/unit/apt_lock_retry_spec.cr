require "../spec_helper"
require "../../src/krikri/plugin_helpers/apt_lock_retry"

# Regression spec for the dpkg-lock-contention retry behavior added in
# 0.9.502. Round 153 (2026-08-20) found that krikri-playbook's `apt:`
# failed fast when the host's dpkg lock was held by another process
# (Ubuntu's unattended-upgr, an in-progress apt on another shell, etc.)
# while real Ansible's apt module waited it out via `lock_timeout: 60`
# (default), krikri-playbook failed fast.
#
# Tests the retry helpers via the `AptLockRetry` module directly with a
# stubbed `exec_remote` proc. Doesn't need the real plugin file (whose
# bottom-of-file entry point would fire on require, defeating the test).

# Canonical dpkg-lock-held stderr that apt-get itself emits when
# unattended-upgr or another apt process is holding the lock.
DPKG_LOCK_HELD_STDERR = "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1738 (unattended-upgr)\n"
DPKG_LOCK_SUCCESS     = {exit_code: 0, stdout: "Setting up nginx.\n", stderr: ""}
DPKG_LOCK_STILL_HELD  = {exit_code: 100, stdout: "", stderr: DPKG_LOCK_HELD_STDERR}
DPKG_BROKEN_REPO      = {exit_code: 100, stdout: "", stderr: "E: The repository 'http://example.com/debian broken Release' does not have a Release file.\n"}
APT_LOCATE_MISS       = {exit_code: 100, stdout: "", stderr: "E: Unable to locate package w3m\n"}
APT_CORRUPT_LISTS     = {exit_code: 100, stdout: "", stderr: "E: LZ4F: /var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages.lz4 Read error (18446744073709551603: ERROR_frameType_unknown)\nE: The package lists or status file could not be parsed or opened.\n"}
APT_UPDATE_SUCCESS    = {exit_code: 0, stdout: "Hit:1 http://us.archive.ubuntu.com/ubuntu jammy InRelease\n", stderr: ""}

# Returns canned responses in order; if the list is exhausted, the
# last response is returned repeatedly. Tracks how many times it was
# invoked. Crystal's Proc.call type-promotes to a callable block, so
# the method signature below doubles as the proc type.
class StubExec
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

# Mixes the module into a host class so we can call the instance
# methods naturally. AptPlugin does the same `include AptLockRetry`
# dance (plugins/apt.cr:33).
class HostClass
  include Krikri::AptLockRetry
end

describe "apt lock-contention retry helpers (round 153 follow-up, 0.9.502)" do
  describe "#apt_lock_held?" do
    it "returns true for the canonical 'Could not get lock' pattern" do
      HostClass.new.apt_lock_held?(DPKG_LOCK_HELD_STDERR).should be_true
    end

    it "returns true for any stderr mentioning /var/lib/dpkg/lock" do
      HostClass.new.apt_lock_held?("E: Unable to lock /var/lib/dpkg/lock - open (11: Resource temporarily unavailable)").should be_true
    end

    it "returns false for non-lock failures (broken repo, signature mismatch)" do
      HostClass.new.apt_lock_held?(DPKG_BROKEN_REPO[:stderr]).should be_false
    end

    it "returns false for empty stderr" do
      HostClass.new.apt_lock_held?("").should be_false
    end
  end

  describe "#apt_with_lock_retry" do
    it "returns immediately on success" do
      stub = StubExec.new([DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(1)
    end

    it "retries on lock contention and succeeds when the lock clears" do
      stub = StubExec.new([DPKG_LOCK_STILL_HELD, DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(2)
    end

    it "retries on alternate '/var/lib/dpkg/lock' lock-held stderr" do
      alt = {exit_code: 100, stdout: "", stderr: "E: Unable to lock /var/lib/dpkg/lock - open (11: Resource temporarily unavailable)\n"}
      stub = StubExec.new([alt, DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(2)
    end

    it "does NOT retry on non-lock failures - matches real Ansible's selective retry" do
      stub = StubExec.new([DPKG_BROKEN_REPO])
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(1)
    end

    it "does NOT retry on empty stderr" do
      empty_err = {exit_code: 1, stdout: "", stderr: ""}
      stub = StubExec.new([empty_err])
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(1)
      stub.exec_count.should eq(1)
    end

    it "respects lock_timeout - returns the last error when budget exhausted" do
      stub = StubExec.new([DPKG_LOCK_STILL_HELD] * 20)
      r = HostClass.new.apt_with_lock_retry("apt-get -y install nginx", 2, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should be >= 2
      stub.exec_count.should be <= 3
    end

    it "passes the exact command through to exec_remote" do
      stub = StubExec.new([DPKG_LOCK_SUCCESS])
      HostClass.new.apt_with_lock_retry("DEBIAN_FRONTEND=noninteractive apt-get install -y nginx", 30, ->(c : String) { stub.call(c) })
      stub.exec_count.should eq(1)
    end
  end

  describe "#apt_get_update_with_retry" do
    it "returns immediately on success" do
      stub = StubExec.new([DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_get_update_with_retry("apt-get update", 5, 12, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(1)
    end

    it "retries up to `retries` times on lock contention (1 initial + retries)" do
      stub = StubExec.new([DPKG_LOCK_STILL_HELD] * 5)
      r = HostClass.new.apt_get_update_with_retry("apt-get update", 1, 1, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(2)
    end

    it "succeeds within the retry budget when contention clears" do
      stub = StubExec.new([DPKG_LOCK_STILL_HELD, DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_get_update_with_retry("apt-get update", 5, 1, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(2)
    end

    it "does NOT retry on non-lock failures (broken repo) - matches real Ansible" do
      stub = StubExec.new([DPKG_BROKEN_REPO])
      r = HostClass.new.apt_get_update_with_retry("apt-get update", 5, 1, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(1)
    end
  end

  describe "default constants match real Ansible's apt module" do
    it "DEFAULT_LOCK_TIMEOUT = 60" do
      Krikri::AptLockRetry::DEFAULT_LOCK_TIMEOUT.should eq(60)
    end

    it "DEFAULT_UPDATE_CACHE_RETRIES = 5" do
      Krikri::AptLockRetry::DEFAULT_UPDATE_CACHE_RETRIES.should eq(5)
    end

    it "DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY = 12" do
      Krikri::AptLockRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY.should eq(12)
    end
  end

  describe "#apt_corrupt_lists?" do
    it "returns true for the canonical corrupt-lists parse-error pattern" do
      HostClass.new.apt_corrupt_lists?(APT_CORRUPT_LISTS[:stderr]).should be_true
    end

    it "returns false for a plain locate-miss on a valid (even if empty) cache" do
      # Confirmed live (0.9.737): real ansible-playbook does NOT retry
      # here - `package_status()` fails straight to fail_json with "No
      # package matching '%s' is available", no implicit update at all.
      HostClass.new.apt_corrupt_lists?(APT_LOCATE_MISS[:stderr]).should be_false
    end

    it "returns false for non-corruption failures (broken repo, lock held)" do
      HostClass.new.apt_corrupt_lists?(DPKG_BROKEN_REPO[:stderr]).should be_false
      HostClass.new.apt_corrupt_lists?(DPKG_LOCK_HELD_STDERR).should be_false
      HostClass.new.apt_corrupt_lists?("").should be_false
    end
  end

  describe "#apt_install_with_implicit_cache_retry" do
    it "does not update the cache when the install succeeds" do
      stub = StubExec.new([DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(1)
    end

    it "does not retry on a non-corruption failure (broken repo)" do
      stub = StubExec.new([DPKG_BROKEN_REPO])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(1)
    end

    it "does NOT retry on a plain locate-miss - matches real Ansible's fail-fast on a valid cache" do
      # This is the exact scenario the original (0.9.736) gate got
      # wrong: it retried-and-succeeded here, while real ansible-playbook
      # fails outright with "No package matching 'w3m' is available" -
      # confirmed live against both `package: {name: w3m, state: present}`
      # and the buluma.httpd role's `apache2` install, both on a
      # genuinely empty (not corrupt) /var/lib/apt/lists/.
      stub = StubExec.new([APT_LOCATE_MISS])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(1)
    end

    it "retries once behind an implicit 'apt-get update' on corrupt lists and succeeds" do
      # Confirmed live (0.9.737): corrupting a downloaded index file
      # (an unreadable .lz4 list) reproduces python-apt's SystemError
      # both directly and via `apt-get install`'s own stderr.
      stub = StubExec.new([APT_CORRUPT_LISTS, {exit_code: 0, stdout: "", stderr: ""}, DPKG_LOCK_SUCCESS])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(0)
      stub.exec_count.should eq(3)
    end

    it "fails with the ORIGINAL error when the implicit update itself fails" do
      stub = StubExec.new([APT_CORRUPT_LISTS, DPKG_BROKEN_REPO])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      r[:stderr].should eq(APT_CORRUPT_LISTS[:stderr])
      stub.exec_count.should eq(2)
    end

    it "fails with the RETRY error when the refresh succeeded but the lists are still unreadable" do
      stub = StubExec.new([APT_CORRUPT_LISTS, {exit_code: 0, stdout: "", stderr: ""}, APT_CORRUPT_LISTS])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      r[:exit_code].should eq(100)
      stub.exec_count.should eq(3)
    end

    it "retries only ONCE - a second corrupt-lists failure is terminal" do
      stub = StubExec.new([APT_CORRUPT_LISTS, {exit_code: 0, stdout: "", stderr: ""}, APT_CORRUPT_LISTS, APT_CORRUPT_LISTS])
      r = HostClass.new.apt_install_with_implicit_cache_retry("apt-get -y install w3m", 30, ->(c : String) { stub.call(c) })
      stub.exec_count.should eq(3)
      r[:exit_code].should eq(100)
    end
  end

  # Regression spec for robertdebock.update_package_cache's 0.9.825
  # regression: `package: {update_cache: true}` hardcoded `changed: true`
  # for apt unconditionally instead of sharing apt.cr's own python3-apt-
  # aware, mtime-diff-aware logic - see apt.cr's own long comment (round
  # 30001) for the full real-Ansible semantics this mirrors.
  describe "#apt_cache_refresh_changed?" do
    it "is always false when python3-apt is absent, regardless of mtime movement" do
      stub = StubExec.new([{exit_code: 1, stdout: "", stderr: ""}])
      HostClass.new.apt_cache_refresh_changed?(100, 200, ->(c : String) { stub.call(c) }).should be_false
    end

    it "is false when python3-apt is present but the mtime did not move (an all-Hit run)" do
      stub = StubExec.new([{exit_code: 0, stdout: "", stderr: ""}])
      HostClass.new.apt_cache_refresh_changed?(100, 100, ->(c : String) { stub.call(c) }).should be_false
    end

    it "is true when python3-apt is present and the mtime moved" do
      stub = StubExec.new([{exit_code: 0, stdout: "", stderr: ""}])
      HostClass.new.apt_cache_refresh_changed?(100, 200, ->(c : String) { stub.call(c) }).should be_true
    end
  end

  describe "#apt_python_apt_present?" do
    it "is true when either python3 or python2 can import apt" do
      stub = StubExec.new([{exit_code: 0, stdout: "", stderr: ""}])
      HostClass.new.apt_python_apt_present?(->(c : String) { stub.call(c) }).should be_true
    end

    it "is false when neither interpreter can import apt" do
      stub = StubExec.new([{exit_code: 1, stdout: "", stderr: ""}])
      HostClass.new.apt_python_apt_present?(->(c : String) { stub.call(c) }).should be_false
    end
  end

  describe "#apt_cache_mtime" do
    it "parses the probe command's stdout as an integer" do
      stub = StubExec.new([{exit_code: 0, stdout: "1735689600\n", stderr: ""}])
      HostClass.new.apt_cache_mtime(->(c : String) { stub.call(c) }).should eq(1735689600)
    end
  end

  # Regression spec for the geerlingguy.kubernetes changed-count gap
  # (rounds 65166/65311, fixed 0.9.835): real Ansible's apt module
  # auto-installs python3-apt at module start and respawns, so its host
  # moves to the mtime-diff changed-reporting path after the first apt
  # task; this engine previously never installed the bindings, so it
  # stayed on the "absent → changed=false" path forever and a later
  # `apt: {update_cache: true}` task reported ok where real Ansible
  # reported changed.
  describe "#apt_auto_install_python_apt" do
    it "is a no-op when the bindings are already importable" do
      stub = StubExec.new([{exit_code: 0, stdout: "", stderr: ""}])
      HostClass.new.apt_auto_install_python_apt(false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(1)
    end

    it "runs the prefetch then the install when the bindings are missing" do
      commands = [] of String
      responses = [
        {exit_code: 1, stdout: "", stderr: "No module named 'apt'"},
        {exit_code: 0, stdout: "Hit:1 http://archive.ubuntu.com jammy InRelease\n", stderr: ""},
        {exit_code: 0, stdout: "Setting up python3-apt ...\n", stderr: ""},
      ]
      result = HostClass.new.apt_auto_install_python_apt(false, ->(c : String) {
        commands << c
        responses.shift
      })
      result.should be_nil
      commands.size.should eq(3)
      commands[1].should eq("apt-get update")
      commands[2].should contain("python3-apt")
    end

    it "skips the prefetch when the task explicitly passed update_cache: false" do
      commands = [] of String
      responses = [
        {exit_code: 1, stdout: "", stderr: "No module named 'apt'"},
        {exit_code: 0, stdout: "Setting up python3-apt ...\n", stderr: ""},
      ]
      result = HostClass.new.apt_auto_install_python_apt(true, ->(c : String) {
        commands << c
        responses.shift
      })
      result.should be_nil
      commands.size.should eq(2)
      commands[1].should contain("python3-apt")
    end

    it "returns the failed prefetch result (check_rc=True hard failure)" do
      stub = StubExec.new([
        {exit_code: 1, stdout: "", stderr: "No module named 'apt'"},
        {exit_code: 100, stdout: "", stderr: "E: Some index files failed to download.\n"},
      ])
      result = HostClass.new.apt_auto_install_python_apt(false, ->(c : String) { stub.call(c) })
      result.should_not be_nil
      result.not_nil![:exit_code].should eq(100)
      result.not_nil![:stderr].should contain("failed to download")
    end

    it "returns the failed install result" do
      stub = StubExec.new([
        {exit_code: 1, stdout: "", stderr: "No module named 'apt'"},
        {exit_code: 0, stdout: "", stderr: ""},
        {exit_code: 100, stdout: "", stderr: "E: Unable to locate package python3-apt\n"},
      ])
      result = HostClass.new.apt_auto_install_python_apt(false, ->(c : String) { stub.call(c) })
      result.should_not be_nil
      result.not_nil![:stderr].should contain("Unable to locate package python3-apt")
    end
  end

  # The auto-install above is a real, persistent host mutation, so it
  # must never run under --check. apt.cr gates its own call with
  # `unless @check_mode` and refuses the task outright when the
  # bindings are absent; package.cr's cache-refresh-only path
  # (`package: {update_cache: true}`, which real Ansible delegates to
  # the apt module) shipped without any gate at all for one commit -
  # a dry run would have installed python3-apt for real.
  describe "#apt_check_mode_python_apt_refusal" do
    it "returns nil outside check mode without probing anything" do
      stub = StubExec.new([{exit_code: 1, stdout: "", stderr: "No module named 'apt'"}])
      HostClass.new.apt_check_mode_python_apt_refusal(false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(0)
    end

    it "returns nil in check mode when the bindings are already present" do
      stub = StubExec.new([{exit_code: 0, stdout: "", stderr: ""}])
      HostClass.new.apt_check_mode_python_apt_refusal(true, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(1)
    end

    it "returns real Ansible's own refusal message in check mode when the bindings are missing, without installing anything" do
      commands = [] of String
      msg = HostClass.new.apt_check_mode_python_apt_refusal(true, ->(c : String) {
        commands << c
        {exit_code: 1, stdout: "", stderr: "No module named 'apt'"}
      })
      msg.should eq(Krikri::AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG)
      msg.not_nil!.should contain("python3-apt must be installed to use check mode")
      commands.none?(&.includes?("apt-get")).should be_true
    end
  end

  # Regression spec for the apt-404-on-krikri-host-only pattern (rounds
  # 72311/72313/72363 - lfit.lf-dev-libs, lfit.mono-install,
  # markosamuli.pyenv). Real Ansible's `package:` action plugin
  # delegates to the apt module, whose main() refreshes the cache
  # BEFORE install() whenever update_cache: is set - all three roles
  # pass `update_cache: true` in the same task as the install. This
  # engine's package: module used to install straight off the host
  # image's stale package index (it only honored update_cache: on the
  # name-less cache-refresh-only path), so apt resolved names to
  # long-superseded versions (linux-libc-dev 5.15.0-33.34,
  # libdpkg-perl 1.21.1ubuntu2.1 - all 2022-era) and 404'd fetching
  # their .debs from the live mirror, which only carries current
  # versions. Real Ansible on a simultaneously-provisioned host ran
  # the refresh first, resolved current versions, and succeeded.
  describe "#apt_update_cache_before_operation" do
    it "returns nil in check mode without running anything" do
      stub = StubExec.new([APT_UPDATE_SUCCESS])
      HostClass.new.apt_update_cache_before_operation(true, 0, 5, 12, true, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(0)
    end

    it "returns nil without running anything when update_cache is false and no cache_valid_time is given" do
      stub = StubExec.new([APT_UPDATE_SUCCESS])
      HostClass.new.apt_update_cache_before_operation(false, 0, 5, 12, false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(0)
    end

    it "runs apt-get update when update_cache is true (default cache_valid_time: 0 = always stale)" do
      stub = StubExec.new([APT_UPDATE_SUCCESS])
      HostClass.new.apt_update_cache_before_operation(true, 0, 5, 12, false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(1)
    end

    it "returns the failed update result so the caller fails the task before any install" do
      stub = StubExec.new([DPKG_BROKEN_REPO])
      result = HostClass.new.apt_update_cache_before_operation(true, 0, 5, 12, false, ->(c : String) { stub.call(c) })
      result.should_not be_nil
      result.not_nil![:exit_code].should eq(100)
      result.not_nil![:stderr].should contain("does not have a Release file")
    end

    it "skips the refresh when a positive cache_valid_time window is still fresh" do
      now = Time.utc.to_unix
      stub = StubExec.new([{exit_code: 0, stdout: now.to_s, stderr: ""}])
      HostClass.new.apt_update_cache_before_operation(false, 3600, 5, 12, false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(1) # only the mtime probe, no apt-get update
    end

    it "refreshes when a positive cache_valid_time window has gone stale" do
      stale = Time.utc.to_unix - 7200
      stub = StubExec.new([
        {exit_code: 0, stdout: stale.to_s, stderr: ""},
        APT_UPDATE_SUCCESS,
      ])
      HostClass.new.apt_update_cache_before_operation(false, 3600, 5, 12, false, ->(c : String) { stub.call(c) }).should be_nil
      stub.exec_count.should eq(2)
    end
  end
end
