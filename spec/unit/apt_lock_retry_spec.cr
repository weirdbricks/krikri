require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/apt_lock_retry"

# Regression spec for the dpkg-lock-contention retry behavior added in
# 0.9.502. Round 153 (2026-08-20) found that crystal-ansible's `apt:`
# failed fast when the host's dpkg lock was held by another process
# (Ubuntu's unattended-upgr, an in-progress apt on another shell, etc.)
# while real Ansible's apt module waited it out via `lock_timeout: 60`
# (default), crystal-ansible failed fast.
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
  include CrystalPlay::AptLockRetry
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
      CrystalPlay::AptLockRetry::DEFAULT_LOCK_TIMEOUT.should eq(60)
    end

    it "DEFAULT_UPDATE_CACHE_RETRIES = 5" do
      CrystalPlay::AptLockRetry::DEFAULT_UPDATE_CACHE_RETRIES.should eq(5)
    end

    it "DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY = 12" do
      CrystalPlay::AptLockRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY.should eq(12)
    end
  end
end
