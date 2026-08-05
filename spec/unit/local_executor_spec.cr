require "../spec_helper"
require "../../src/crystal_play/local_executor"

describe CrystalPlay::LocalExecutor do
  describe ".exec" do
    it "captures stdout and the exit code for a normal command" do
      result = CrystalPlay::LocalExecutor.exec("echo hello world")
      result[:exit_code].should eq(0)
      result[:stdout].should eq("hello world\n")
      result[:stderr].should eq("")
    end

    it "captures stderr and a nonzero exit code" do
      result = CrystalPlay::LocalExecutor.exec("echo oops >&2; exit 3")
      result[:exit_code].should eq(3)
      result[:stderr].should eq("oops\n")
    end

    it "captures large output in full, without truncation" do
      result = CrystalPlay::LocalExecutor.exec("yes x | head -c 500000")
      result[:exit_code].should eq(0)
      result[:stdout].bytesize.should eq(500000)
    end

    # Regression test for passing argv directly (Process.new("/bin/bash",
    # ["-c", command]), no shell: true) instead of a hand-escaped
    # "/bin/bash -c '...'" string: the command now travels as a single
    # argv element, so it must survive embedded single quotes,
    # backslashes, and "$" untouched, with no shell re-parsing it.
    it "handles embedded single quotes, backslashes, and $ correctly" do
      result = CrystalPlay::LocalExecutor.exec(%(echo 'it'"'"'s a $HOME\\test'))
      result[:exit_code].should eq(0)
      result[:stdout].should eq("it's a $HOME\\test\n")
    end

    # Regression test for a real, previously-shipped bug: `sleep N && daemon &`
    # backgrounds a *shell* that blocks in its own wait() on `daemon` (nohup
    # only suppresses SIGHUP, it doesn't exempt a child from its parent's own
    # wait()) - if `daemon` never exits, neither does that shell, and the
    # stdout/stderr pipe it's still holding open never reaches EOF. Passing
    # output/error as a plain IO makes Process#wait block until EOF, so this
    # used to hang LocalExecutor.exec forever even though the process it
    # actually spawned (the outer bash -c) had long since exited.
    it "does not hang when a backgrounded command chains a never-exiting daemon after &&" do
      marker = File.tempname("local-executor-spec-daemon-marker")

      started = Time.monotonic
      result = CrystalPlay::LocalExecutor.exec("sleep 0.1 && (touch #{marker}; tail -f /dev/null) &")
      elapsed = Time.monotonic - started

      result[:exit_code].should eq(0)
      elapsed.total_seconds.should be < 3.0

      # The backgrounded daemon should still actually be running - this
      # isn't testing that the command failed to start, only that waiting
      # for its own output doesn't block the caller.
      10.times do
        break if File.exists?(marker)
        sleep 50.milliseconds
      end
      File.exists?(marker).should be_true
    ensure
      `pkill -f "tail -f /dev/null" 2>/dev/null`
      File.delete(marker) if marker && File.exists?(marker)
    end
  end
end
