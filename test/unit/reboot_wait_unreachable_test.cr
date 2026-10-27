require "../minitest_helper"
require "../../src/krikri/task_executor/executor_task_exec"

private def fake_result(exit_code : Int32, stderr : String)
  {exit_code: exit_code, stdout: "", stderr: stderr}
end

# Issue #579 (mtze.docker_swap_grub): a reboot-wait probe that hangs gets
# SIGKILLed by the exec timeout, so it returns exit 137 with EMPTY stderr -
# connection_level_failure? only matches exit 255, so the wait loop fell
# through to the FAILED "Timed out waiting" result where ansible-playbook
# reports UNREACHABLE with ssh's own ConnectTimeout line. The decision now
# lives in TaskExecutor.reboot_wait_unreachable_error (pure, testable).
describe Krikri::TaskExecutor do
  describe ".reboot_wait_unreachable_error" do
    it "returns the ConnectTimeout message for a timed-out probe killed with empty stderr" do
      # run_with_timeout SIGKILLs the hung ssh: exit 137, stderr empty.
      Krikri::TaskExecutor.reboot_wait_unreachable_error(fake_result(137, ""), true, "10.0.0.5", 22)
        .must_equal "ssh: connect to host 10.0.0.5 port 22: Connection timed out"
    end

    it "returns the ConnectTimeout message for a timed-out probe whose stderr is only warnings" do
      # ssh may have flushed "Warning: ..." lines before the kill - that
      # is not ansible's error, the ConnectTimeout line is.
      Krikri::TaskExecutor.reboot_wait_unreachable_error(
        fake_result(137, "Warning: Permanently added '10.0.0.5' (ED25519) to the list of hosts known."),
        true, "10.0.0.5", nil
      ).must_equal "ssh: connect to host 10.0.0.5 port 22: Connection timed out"
    end

    it "returns the probe's stderr for a non-timed-out connection-refused failure" do
      Krikri::TaskExecutor.reboot_wait_unreachable_error(
        fake_result(255, "ssh: connect to host 127.0.0.1 port 1: Connection refused"),
        false, "127.0.0.1", 1
      ).must_equal "ssh: connect to host 127.0.0.1 port 1: Connection refused"
    end

    it "returns nil for a reachable host whose test command kept failing" do
      # Host came back but the wait still expired: FAILED timeout path.
      Krikri::TaskExecutor.reboot_wait_unreachable_error(fake_result(1, ""), false, "10.0.0.5", 22)
        .must_be_nil
    end

    it "returns nil for a slow reachable probe that finished with its own status" do
      # Past connect_timeout but not killed (exit 1, not 137): the host is
      # up and only the test command failed, so the FAILED timeout path stays.
      Krikri::TaskExecutor.reboot_wait_unreachable_error(fake_result(1, ""), true, "10.0.0.5", 22)
        .must_be_nil
    end

    it "returns the ConnectTimeout message when the probe exec itself raised" do
      # last_result nil (SSHManager.exec rescue nil) stays unreachable.
      Krikri::TaskExecutor.reboot_wait_unreachable_error(nil, false, "10.0.0.5", 22)
        .must_equal "ssh: connect to host 10.0.0.5 port 22: Connection timed out"
    end
  end
end
