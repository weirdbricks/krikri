require "../spec_helper"
require "../../src/krikri/ssh_manager"

# Real bug found benchmarking buluma.netdata (round 163 regression
# check): Krikri::SSHManager's per-command execution timeout was a
# hardcoded 300s (5 minutes) default shared by #exec/#exec_script/
# #daemon_send. Real Ansible has no default command-duration limit at
# all - a foreground task runs until it completes, however long that
# takes. netdata's own installer genuinely compiles from source and
# took a confirmed 1536s (~25.6 minutes) against real ansible-playbook;
# crystal's identical task was killed at exactly 300s despite the
# remote command still actively running and eventually succeeding.
# This spec is a deliberately blunt guard against the default silently
# regressing back down to something too short for realistic real-world
# tasks (compiles, large package installs) - not a behavioral test of
# the timeout mechanism itself (that needs a real SSH round trip,
# already covered qualitatively by plugin_daemon_spec.cr's own local-
# pipe stand-in for the wire protocol).
describe Krikri::SSHManager do
  it "defaults the per-command execution timeout to at least 30 minutes" do
    Krikri::SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS.should be >= 1800
  end

  describe ".run_with_timeout" do
    it "returns the block's result when the process finishes in time" do
      process = Process.new("sleep", ["0.05"])
      result = Krikri::SSHManager.run_with_timeout(process, 5) do |proc|
        status = proc.wait
        {exit_code: status.exit_code, stdout: "done", stderr: ""}
      end

      result[:exit_code].should eq(0)
      result[:stdout].should eq("done")
    end

    it "SIGKILLs the process and returns its real exit status when the timeout fires" do
      process = Process.new("sleep", ["30"])
      start = Time.monotonic

      result = Krikri::SSHManager.run_with_timeout(process, 1) do |proc|
        status = proc.wait
        {exit_code: status.exit_code, stdout: "", stderr: ""}
      end

      elapsed = Time.monotonic - start
      # Bounded by timeout + the 5s grace - the old unenforced-timeout
      # bug would have taken the full 30s (or hung forever).
      elapsed.should be < 10.seconds
      # The SIGKILLed child surfaces as an abnormal exit inside the
      # block (Crystal's Process#wait has no exit code for a signal
      # death), which run_with_timeout's rescue converts to 255.
      result[:exit_code].should eq(255)
    end

    it "reports a 255 with the error message when the block raises" do
      process = Process.new("true", [] of String)
      result = Krikri::SSHManager.run_with_timeout(process, 5) do |_proc|
        raise "synthetic block failure"
        {exit_code: 0, stdout: "", stderr: ""}
      end

      result[:exit_code].should eq(255)
      result[:stderr].should contain("synthetic block failure")
    end
  end
end
