require "../minitest_helper"

# Regression for issue #706: a full-suite flake saw a parallel test's
# ENV["PATH"] read raise KeyError while the only PATH-blanking tests were
# marked exclusive!. The exclusive! gate is supposed to quiesce every other
# test (parallel ones at the run_one gate, serial ones on STATE_MUTEX), so
# the blank window must be unobservable. This file pins that with a
# sentinel: exclusive tests blank KRIKRI_GATE_SENTINEL_706 for a few ms at
# a time, while parallel tests capture-and-restore the sentinel the way
# the suite's PATH shims do - so a leak of the blank window into a parallel
# test's capture would cascade: the nil capture is "restored" as a delete,
# and every later reader fails.
private SENTINEL = "KRIKRI_GATE_SENTINEL_706"

ENV[SENTINEL] = "present"

describe "exclusive gate: parallel readers never see the blank window (#706)" do
  it "reads the sentinel continuously while exclusive tests blank it" do
    60.times do
      # ENV[...]? not ENV[...]: the failure must be a VALUE failure ("nil
      # seen"), never a KeyError raised by a concurrent blanker.
      ENV[SENTINEL]?.must_equal("present")
      sleep 1.millisecond
    end
  end

  it "captures and restores the sentinel the way the suite's PATH shims do" do
    previous = ENV[SENTINEL]?
    begin
      sleep 5.milliseconds
    ensure
      previous ? (ENV[SENTINEL] = previous) : ENV.delete(SENTINEL)
    end
    ENV[SENTINEL]?.must_equal("present")
  end
end

describe "exclusive gate: blank windows stay unobservable (#706)" do
  exclusive! # the sentinel blank is process-wide, like the PATH blank that flaked

  it "blanks the sentinel while no other test may run (window 1)" do
    10.times do
      ENV.delete(SENTINEL)
      begin
        sleep 5.milliseconds
      ensure
        ENV[SENTINEL] = "present"
      end
      Fiber.yield
    end
    ENV[SENTINEL]?.must_equal("present")
  end

  it "blanks the sentinel while no other test may run (window 2)" do
    10.times do
      ENV.delete(SENTINEL)
      begin
        sleep 5.milliseconds
      ensure
        ENV[SENTINEL] = "present"
      end
      Fiber.yield
    end
    ENV[SENTINEL]?.must_equal("present")
  end
end
