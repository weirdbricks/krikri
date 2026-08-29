require "../spec_helper"
require "../../src/crystal_play/timing_profile"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item #0 (`--timing-profile`).
#
# The load-bearing property of TimingProfile is not "it can time a
# block" - it is that overlapping buckets do not double-count, because
# every number the rest of the perf work is judged against comes out of
# here. `SSHManager.upload` runs a chmod through `SSHManager.exec`, and
# `ConditionalEvaluator.evaluate` renders through
# `VarSubstitutor#substitute`; if the inner span were added to the
# outer one the percentages would exceed 100% for a purely sequential
# run and every before/after comparison built on them would be wrong.
describe CrystalPlay::TimingProfile do
  after_each do
    CrystalPlay::TimingProfile.disable
  end

  it "is a bare yield when disabled - nothing is recorded" do
    CrystalPlay::TimingProfile.disable
    value = CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") { 42 }

    value.should eq(42)
    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(0)
  end

  it "records a call and a duration when enabled" do
    CrystalPlay::TimingProfile.enable
    CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }

    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(1)
    CrystalPlay::TimingProfile.nanos("transport.ssh_exec").should be > 1_000_000
  end

  it "passes the block's value through" do
    CrystalPlay::TimingProfile.enable
    CrystalPlay::TimingProfile.measure("controller.templating", "controller") { "rendered" }.should eq("rendered")
  end

  it "attributes a re-entrant same-group span entirely to the outermost bucket" do
    CrystalPlay::TimingProfile.enable

    CrystalPlay::TimingProfile.measure("transport.scp_upload", "transport") do
      sleep 5.milliseconds
      # Exactly the shape of SSHManager.upload's own trailing chmod,
      # which goes back through SSHManager.exec.
      CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }
    end

    CrystalPlay::TimingProfile.count("transport.scp_upload").should eq(1)
    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(0)
    CrystalPlay::TimingProfile.nanos("transport.ssh_exec").should eq(0)
  end

  it "still counts a different group nested inside one (the sub-bucket case)" do
    CrystalPlay::TimingProfile.enable

    CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") do
      CrystalPlay::TimingProfile.measure("transport.ssh_spawn", "transport.spawn") { sleep 2.milliseconds }
      sleep 3.milliseconds
    end

    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(1)
    CrystalPlay::TimingProfile.count("transport.ssh_spawn").should eq(1)
    # The sub-bucket is a slice OF the parent, so it must be smaller.
    CrystalPlay::TimingProfile.nanos("transport.ssh_spawn").should be < CrystalPlay::TimingProfile.nanos("transport.ssh_exec")
  end

  it "restores the group after an exception so a later span is still measured" do
    CrystalPlay::TimingProfile.enable

    expect_raises(Exception, "boom") do
      CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") { raise "boom" }
    end
    CrystalPlay::TimingProfile.measure("transport.scp_upload", "transport") { sleep 2.milliseconds }

    # The failed span is still a real span that happened, and the group
    # must not be left latched - a latched group would silently swallow
    # every subsequent transport measurement in the run.
    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(1)
    CrystalPlay::TimingProfile.count("transport.scp_upload").should eq(1)
    CrystalPlay::TimingProfile.nanos("transport.scp_upload").should be > 0
  end

  it "treats concurrent fibers in the same group as concurrency, not re-entrancy" do
    # --forks > 1 runs one fiber per host; host B entering `transport`
    # while host A is parked inside it must not be mistaken for a
    # nested call, or every host but the first would go unmeasured.
    CrystalPlay::TimingProfile.enable

    done = Channel(Nil).new
    2.times do
      spawn do
        CrystalPlay::TimingProfile.measure("transport.ssh_exec", "transport") { sleep 5.milliseconds }
        done.send(nil)
      end
    end
    2.times { done.receive }

    CrystalPlay::TimingProfile.count("transport.ssh_exec").should eq(2)
  end

  it "reports only buckets that were actually measured" do
    CrystalPlay::TimingProfile.enable
    CrystalPlay::TimingProfile.measure("transport.daemon_send", "transport") { }

    io = IO::Memory.new
    CrystalPlay::TimingProfile.report(io)
    output = io.to_s

    output.should contain("TIMING PROFILE")
    output.should contain("daemon request")
    output.should_not contain("rsync upload")
  end

  it "prints nothing at all when disabled" do
    CrystalPlay::TimingProfile.disable
    io = IO::Memory.new
    CrystalPlay::TimingProfile.report(io)
    io.to_s.should be_empty
  end
end
