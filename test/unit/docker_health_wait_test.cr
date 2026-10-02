require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_health_wait"

# The wait loop of community.docker docker_container state=healthy,
# ported from real's module_utils/module_container/module.py
# wait_for_state (called there with wait_states=['starting',
# 'unhealthy'], complete_states=['healthy', None],
# max_wait=healthy_wait_timeout, health_state=True). The failure
# wordings (including real's own "Encontered" typo) and the
# exponential-backoff/timeout arithmetic below were verified against
# real's source; the timeout and unhealthy-keeps-waiting behaviors
# were additionally verified live against real ansible-playbook 2.19.11
# (see the plugin's doc comment).
module DockerHealthWaitSpecHelpers
  # Raised when the canned sequence is exhausted - keeps fake_inspect
  # from repeating its last entry forever (which would hang tests that
  # use max_wait: nil).
  class Exhausted < Exception; end

  # Builds an inspect_fn returning canned inspect JSONs in sequence
  # (the last entry repeats, until max_calls is reached, whereupon it
  # raises Exhausted so no-test can hang), recording every sleep
  # delay. Each canned entry is a Health.Status string, or nil for
  # "no healthcheck" (State.Health absent), or :vanished for a nil
  # inspect result.
  def self.fake_inspect(sequence : Array(String? | Symbol), max_calls : Int32 = 1000)
    calls = 0
    sleeps = [] of Float64
    inspect_fn = Krikri::PluginHelpers::DockerHealthWait::InspectFn.new do
      raise Exhausted.new("max_calls reached") if calls >= max_calls
      entry = sequence[calls < sequence.size ? calls : sequence.size - 1]
      calls += 1
      next nil if entry == :vanished
      if entry.nil?
        JSON.parse(%({"State": {"Status": "running"}}))
      else
        JSON.parse(%({"State": {"Status": "running", "Health": {"Status": "#{entry}"}}}))
      end
    end
    sleep_fn = Krikri::PluginHelpers::DockerHealthWait::SleepFn.new { |delay| sleeps << delay }
    {inspect_fn, sleeps, -> { calls }, sleep_fn}
  end
end

describe Krikri::PluginHelpers::DockerHealthWait do
  include RaisesAssertion

  describe ".wait_for_healthy" do
    it "returns the inspect JSON immediately when there is no healthcheck (None = healthy)" do
      inspect_fn, sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect([nil])
      result = Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", 300.0, inspect_fn, sleep_fn)
      result.as_h["State"].as_h["Health"]?.must_be_nil
      sleeps.must_equal([] of Float64)
      calls.call.must_equal(1)
    end

    it "returns the inspect JSON immediately when the status is already healthy" do
      inspect_fn, sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["healthy"])
      result = Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", 300.0, inspect_fn, sleep_fn)
      result.as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("healthy")
      sleeps.must_equal([] of Float64)
      calls.call.must_equal(1)
    end

    it "polls through 'starting' with real's exponential backoff (1.0, *1.1, cap 10) until healthy" do
      inspect_fn, sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["starting", "starting", "healthy"])
      result = Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", 300.0, inspect_fn, sleep_fn)
      result.as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("healthy")
      sleeps.must_equal([1.0, 1.1])
      calls.call.must_equal(3)
    end

    it "keeps waiting through 'unhealthy' (a wait state, not an immediate failure) and caps the delay at 10s" do
      # 30 polls all unhealthy with no timeout: delays 1.0, 1.1, 1.21,
      # ... capped at 10.0 once 1.1**n would exceed it (1.1**24 < 10,
      # 1.1**25 > 10 - real's own comment). The fake inspect raises
      # Exhausted after 30 calls so the no-timeout loop is bounded.
      sequence = Array(String? | Symbol).new(30, "unhealthy")
      inspect_fn, sleeps, calls, _sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(sequence, max_calls: 30)
      assert_raises(DockerHealthWaitSpecHelpers::Exhausted) do
        Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", nil, inspect_fn, _sleep_fn)
      end
      calls.call.must_equal(30)
      sleeps.size.must_equal(30)
      sleeps.first.must_equal(1.0)
      sleeps[2].must_be_close_to(1.21, 1e-9)
      sleeps.last.must_equal(10.0)
      sleeps.select { |delay| delay > 10.0 }.must_be_empty
    end

    it "fails with real's timeout wording when max_wait is exceeded, carrying the last inspect as container" do
      inspect_fn, sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["unhealthy"])
      error = assert_raises(Krikri::PluginHelpers::DockerHealthWait::Failure) do
        Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("cid123", 2.5, inspect_fn, sleep_fn)
      end
      error.message.to_s.must_equal(
        %(Timeout of 2.5 seconds exceeded while waiting for container "cid123"))
      last = error.container_json || raise "container_json missing"
      last.as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("unhealthy")
      # Real's clamp-then-check arithmetic: sleeps 1.0, 1.1, then
      # clamped to 2.5 - 2.1 = ~0.4, then a final clamped-to-zero sleep
      # (2.5 + next delay > 2.5), and only the NEXT loop's
      # delay < 1e-4 escape fires the timeout - five inspects, four
      # sleeps, the last one zero.
      sleeps.size.must_equal(4)
      sleeps[0].must_equal(1.0)
      sleeps[1].must_be_close_to(1.1, 1e-9)
      sleeps[2].must_be_close_to(0.4, 1e-9)
      sleeps[3].must_equal(0.0)
      calls.call.must_equal(5)
    end

    it "formats the timeout with Float64 wording like real (8.0, not 8)" do
      inspect_fn, _sleeps, _calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["starting"])
      error = assert_raises(Krikri::PluginHelpers::DockerHealthWait::Failure) do
        Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", 8.0, inspect_fn, sleep_fn)
      end
      error.message.to_s.must_include("Timeout of 8.0 seconds exceeded")
    end

    it "fails with real's vanished-container wording (typo mirrored) when inspect returns nil" do
      inspect_fn, sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["starting", :vanished])
      error = assert_raises(Krikri::PluginHelpers::DockerHealthWait::Failure) do
        Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", nil, inspect_fn, sleep_fn)
      end
      error.message.to_s.must_equal(
        %(Encontered vanished container while waiting for container "id0"))
      error.container_json.must_be_nil
      sleeps.must_equal([1.0])
      calls.call.must_equal(2)
    end

    it "fails with real's unexpected-state wording for a health status outside both state lists" do
      inspect_fn, _sleeps, _calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["bogus"])
      error = assert_raises(Krikri::PluginHelpers::DockerHealthWait::Failure) do
        Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", nil, inspect_fn, sleep_fn)
      end
      error.message.to_s.must_equal(
        %(Encontered unexpected state "bogus" while waiting for container "id0"))
      last = error.container_json || raise "container_json missing"
      last.as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("bogus")
    end

    it "runs forever without a timeout when max_wait is nil (real's <= 0 convention)" do
      inspect_fn, _sleeps, calls, sleep_fn = DockerHealthWaitSpecHelpers.fake_inspect(["unhealthy", "unhealthy", "healthy"])
      result = Krikri::PluginHelpers::DockerHealthWait.wait_for_healthy("id0", nil, inspect_fn, sleep_fn)
      result.as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("healthy")
      calls.call.must_equal(3)
    end
  end

  describe ".health_status" do
    it "reads State.Health.Status" do
      json = JSON.parse(%({"State": {"Status": "running", "Health": {"Status": "starting"}}}))
      Krikri::PluginHelpers::DockerHealthWait.health_status(json).must_equal("starting")
    end

    it "returns nil when Health is missing (no healthcheck) and when State is missing" do
      Krikri::PluginHelpers::DockerHealthWait.health_status(JSON.parse(%({"State": {"Status": "running"}}))).must_be_nil
      Krikri::PluginHelpers::DockerHealthWait.health_status(JSON.parse(%({}))).must_be_nil
    end
  end
end
