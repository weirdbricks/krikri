require "../minitest_helper"
require "../../src/krikri/timing_profile"

# Perf item #0 (`--timing-profile`).
#
# The load-bearing property of TimingProfile is not "it can time a
# block" - it is that overlapping buckets do not double-count, because
# every number the rest of the perf work is judged against comes out of
# here. `SSHManager.upload` runs a chmod through `SSHManager.exec`, and
# `ConditionalEvaluator.evaluate` renders through
# `VarSubstitutor#substitute`; if the inner span were added to the
# outer one the percentages would exceed 100% for a purely sequential
# run and every before/after comparison built on them would be wrong.
private def with_timing(&)
  PluginSpecHelper::STATE_MUTEX.synchronize do
    begin
      Krikri::TimingProfile.disable
      yield
    ensure
      Krikri::TimingProfile.disable
    end
  end
end

describe Krikri::TimingProfile do
  include RaisesAssertion

  it "is a bare yield when disabled - nothing is recorded" do
    with_timing do
      Krikri::TimingProfile.disable
      value = Krikri::TimingProfile.measure("transport.ssh_exec", "transport") { 42 }

      value.must_equal(42)
      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(0)
    end
  end

  it "records a call and a duration when enabled" do
    with_timing do
      Krikri::TimingProfile.enable
      Krikri::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }

      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(1)
      expect((Krikri::TimingProfile.nanos("transport.ssh_exec")) > (1_000_000)).must_equal(true)
    end
  end

  it "passes the block's value through" do
    with_timing do
      Krikri::TimingProfile.enable
      Krikri::TimingProfile.measure("controller.templating", "controller") { "rendered" }.must_equal("rendered")
    end
  end

  it "attributes a re-entrant same-group span entirely to the outermost bucket" do
    with_timing do
      Krikri::TimingProfile.enable

      Krikri::TimingProfile.measure("transport.scp_upload", "transport") do
        sleep 5.milliseconds
        # Exactly the shape of SSHManager.upload's own trailing chmod,
        # which goes back through SSHManager.exec.
        Krikri::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }
      end

      Krikri::TimingProfile.count("transport.scp_upload").must_equal(1)
      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(0)
      Krikri::TimingProfile.nanos("transport.ssh_exec").must_equal(0)
    end
  end

  it "still counts a different group nested inside one (the sub-bucket case)" do
    with_timing do
      Krikri::TimingProfile.enable

      Krikri::TimingProfile.measure("transport.ssh_exec", "transport") do
        Krikri::TimingProfile.measure("transport.ssh_spawn", "transport.spawn") { sleep 2.milliseconds }
        sleep 3.milliseconds
      end

      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(1)
      Krikri::TimingProfile.count("transport.ssh_spawn").must_equal(1)
      # The sub-bucket is a slice OF the parent, so it must be smaller.
      expect((Krikri::TimingProfile.nanos("transport.ssh_spawn")) < (Krikri::TimingProfile.nanos("transport.ssh_exec"))).must_equal(true)
    end
  end

  it "restores the group after an exception so a later span is still measured" do
    with_timing do
      Krikri::TimingProfile.enable

      assert_raises_message(Exception, "boom") do
        Krikri::TimingProfile.measure("transport.ssh_exec", "transport") { raise "boom" }
      end
      Krikri::TimingProfile.measure("transport.scp_upload", "transport") { sleep 2.milliseconds }

      # The failed span is still a real span that happened, and the group
      # must not be left latched - a latched group would silently swallow
      # every subsequent transport measurement in the run.
      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(1)
      Krikri::TimingProfile.count("transport.scp_upload").must_equal(1)
      expect((Krikri::TimingProfile.nanos("transport.scp_upload")) > (0)).must_equal(true)
    end
  end

  it "treats concurrent fibers in the same group as concurrency, not re-entrancy" do
    with_timing do
      # --forks > 1 runs one fiber per host; host B entering `transport`
      # while host A is parked inside it must not be mistaken for a
      # nested call, or every host but the first would go unmeasured.
      Krikri::TimingProfile.enable

      done = Channel(Nil).new
      2.times do
        spawn do
          Krikri::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }
          done.send(nil)
        end
      end
      2.times { done.receive }

      Krikri::TimingProfile.count("transport.ssh_exec").must_equal(2)
    end
  end

  it "reports only buckets that were actually measured" do
    with_timing do
      Krikri::TimingProfile.enable
      Krikri::TimingProfile.measure("transport.daemon_send", "transport") { }

      io = IO::Memory.new
      Krikri::TimingProfile.report(io)
      output = io.to_s

      output.must_include("TIMING PROFILE")
      output.must_include("daemon request")
      output.wont_include("rsync upload")
    end
  end

  it "prints nothing at all when disabled" do
    with_timing do
      Krikri::TimingProfile.disable
      io = IO::Memory.new
      Krikri::TimingProfile.report(io)
      io.to_s.must_be_empty
    end
  end
end
