require "../../src/krikri/plugin_helpers/apt_repository_cache_retry"
require "spec"

# Regression specs for PluginHelpers::AptRepositoryCacheRetry - the
# apt_repository plugin's update_cache_retries/update_cache_retry_max_delay
# support. The delay formula mirrors real ansible-core's own
# apt_repository.py (`delay = 2 ** retry + randomize`, capped at
# `update_cache_retry_max_delay + randomize`, verified against
# /usr/lib/python3/dist-packages/ansible/modules/apt_repository.py);
# the retry loop mirrors its `for retry in range(update_cache_retries)`
# attempt bound. The exec endpoint is injected so nothing here touches a
# real apt-get; max_delay is kept tiny so the between-attempt sleeps
# stay well under a second each.
private class RetryHarness
  include Krikri::AptRepositoryCacheRetry

  getter calls : Array(String) = [] of String

  def run(retries : Int32, max_delay : Int32, fail_first : Int32 = Int32::MAX)
    exec = ->(command : String) {
      @calls << command
      if @calls.size <= fail_first
        {exit_code: 100, stdout: "", stderr: "E: simulated fetch failure"}
      else
        {exit_code: 0, stdout: "ok", stderr: ""}
      end
    }
    apt_repository_cache_update_with_retry(retries, max_delay, exec)
  end
end

describe Krikri::AptRepositoryCacheRetry do
  describe "#apt_repository_retry_delay" do
    it "matches real Ansible's exponential backoff (2**retry + jitter)" do
      harness = RetryHarness.new
      harness.apt_repository_retry_delay(0, 12, jitter: 0.5).should eq(1.5)
      harness.apt_repository_retry_delay(1, 12, jitter: 0.5).should eq(2.5)
      harness.apt_repository_retry_delay(2, 12, jitter: 0.5).should eq(4.5)
      harness.apt_repository_retry_delay(3, 12, jitter: 0.5).should eq(8.5)
    end

    it "caps the delay at update_cache_retry_max_delay + jitter" do
      harness = RetryHarness.new
      harness.apt_repository_retry_delay(4, 12, jitter: 0.25).should eq(12.25)
      harness.apt_repository_retry_delay(9, 3, jitter: 0.0).should eq(3.0)
    end
  end

  describe "#apt_repository_cache_update_with_retry" do
    it "retries a failing update up to update_cache_retries total attempts" do
      harness = RetryHarness.new
      result = harness.run(retries: 3, max_delay: 0)
      result[:exit_code].should eq(100)
      harness.calls.size.should eq(3)
      harness.calls.all? { |call| call == "apt-get update" }.should be_true
    end

    it "stops retrying once an attempt succeeds" do
      harness = RetryHarness.new
      result = harness.run(retries: 5, max_delay: 0, fail_first: 2)
      result[:exit_code].should eq(0)
      harness.calls.size.should eq(3)
    end

    it "makes exactly one attempt when retries is 1" do
      harness = RetryHarness.new
      harness.run(retries: 1, max_delay: 0)
      harness.calls.size.should eq(1)
    end

    it "defaults match real Ansible's argument_spec (5 retries, 12s cap)" do
      Krikri::AptRepositoryCacheRetry::DEFAULT_UPDATE_CACHE_RETRIES.should eq(5)
      Krikri::AptRepositoryCacheRetry::DEFAULT_UPDATE_CACHE_RETRY_MAX_DELAY.should eq(12)
    end
  end
end
