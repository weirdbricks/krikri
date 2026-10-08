require "../minitest_helper"
require "../../src/krikri/ssh_manager"

# Real bug found via round 601090 (robertdebock.common, kata backend,
# warm rerun): a host the cold run's reboot had killed came back as
# "ssh: connect to host ... No route to host" on every dispatch, and
# krikri booked each one as a generic "Plugin execution failed on
# remote" FAILED task while ansible-playbook booked UNREACHABLE
# and halted the host at Gathering Facts (recap `unreachable=1
# failed=0` vs this engine's `failed=2 ok=3 skipped=5`). Distinguishing
# the two is SSHManager.connection_level_failure?'s job: its pattern
# list below is the single source of truth shared by
# PluginManager.interpret_remote_result (which stamps the result) and
# the batch-script transport. These specs pin BOTH directions of the
# classification - a remote plugin crash (loader error, traceback, a
# plain "Permission denied" from touching a root-owned file) must never
# be mistaken for the transport dying, and a real ssh(1) connection
# error must always be caught.
describe "Krikri::SSHManager (ssh_connection_failure_test.cr)" do
  describe ".connection_level_failure?" do
    it "recognizes ssh's own connect-failure stderr shapes" do
      {
        "ssh: connect to host 10.99.10.2 port 22: No route to host",
        "ssh: connect to host 10.255.255.1 port 22: Connection timed out",
        "ssh: connect to host 127.0.0.1 port 1: Connection refused",
        "ssh: connect to host 10.0.0.1 port 22: Network is unreachable",
        "ssh: Could not resolve hostname nosuchhost.invalid: Name or service not known",
        "root@10.0.0.1: Permission denied (publickey,password).",
        "kex_exchange_identification: read: Connection reset by peer",
        "ssh_exchange_identification: Connection closed by remote host",
        "Host key verification failed.",
        "Received disconnect from 209.208.110.195 port 22:2: Too many authentication failures\nDisconnected from 209.208.110.195 port 22",
        "Too many authentication failures",
      }.each do |stderr|
        Krikri::SSHManager.connection_level_failure?(255, stderr).must_equal(true, "#{stderr.inspect} should classify as a connection-level failure")
      end
    end

    it "recognizes krikri's own synthesized transport-failure shapes" do
      {
        "SSH command timed out after 3600s (host likely unreachable) and did not exit even after being killed",
        "SSH execution failed: Broken pipe",
        "SSH script execution failed: Broken pipe",
      }.each do |stderr|
        Krikri::SSHManager.connection_level_failure?(255, stderr).must_equal(true)
      end
    end

    it "never classifies a remote plugin crash as a connection failure" do
      {
        "error while loading shared libraries: libxml2.so.2: cannot open shared object file",
        "Traceback (most recent call last):\n  File \"/tmp/x.py\", line 1, in <module>\nNameError: name 'x' is not defined",
        "/bin/bash: /var/tmp/.krikri-playbook-root-x/plugins/facts: No such file or directory",
        "touch: cannot touch '/etc/hosts': Permission denied",
        "sudo: a password is required",
      }.each do |stderr|
        Krikri::SSHManager.connection_level_failure?(127, stderr).must_equal(false, "#{stderr.inspect} should NOT classify as a connection-level failure")
      end
    end

    it "does not classify a successful run even with transport-shaped text in stderr" do
      # A remote command's own output can mention transport-adjacent
      # text (e.g. a curl timing out); exit 0 means the transport was
      # fine, so the exit-code gate wins.
      Krikri::SSHManager.connection_level_failure?(0, "ssh: connect to host 10.0.0.1 port 22: Connection timed out").must_equal(false)
    end

    it "does not match a bare transport-adjacent phrase without ssh's own prefix" do
      # The conservative direction: a remote curl/nc's stderr can carry
      # "Connection timed out"/"Connection refused" on its own; only
      # ssh's own "ssh: connect to host ..." prefix is evidence of the
      # transport dying.
      Krikri::SSHManager.connection_level_failure?(7, "curl: (7) Failed to connect to 10.0.0.1 port 80: Connection refused").must_equal(false)
      Krikri::SSHManager.connection_level_failure?(7, "nc: connect to 10.0.0.1 port 22 (tcp) failed: Connection timed out").must_equal(false)
    end

    it "classifies a silent mid-execution ssh death (bare 255, both streams empty) as a connection failure" do
      # Live shape (2026-10-07, throwaway podman sshd killed mid-`sleep`):
      # a clean TCP close mid-execution makes ssh exit 255 with NO text
      # at all - no "Connection closed by", no reset notice. Real
      # ansible-playbook books the task UNREACHABLE; without this rule
      # the engine booked a generic FAILED task (solo path) or silently
      # skipped the whole batch (batch path).
      Krikri::SSHManager.connection_level_failure?(255, "", "").must_equal(true)
      # ssh's own first-contact "Warning: Permanently added" line is not
      # remote output - a first-connection host-key acceptance followed
      # by a mid-execution death lands here.
      Krikri::SSHManager.connection_level_failure?(255, "Warning: Permanently added '[127.0.0.1]:22991' (ED25519) to the list of known hosts.\n", "").must_equal(true)
    end

    it "keeps evidence-bearing nonzero exits out of the silent-death rule" do
      # A plugin that produced output ran - its death is not provably
      # transport-level.
      Krikri::SSHManager.connection_level_failure?(255, "", "some plugin output").must_equal(false)
      # A remote signal death arrives through sshd as 128+N, never bare 255.
      Krikri::SSHManager.connection_level_failure?(137, "", "").must_equal(false)
      # A plain nonzero remote exit status is the plugin's own.
      Krikri::SSHManager.connection_level_failure?(3, "", "").must_equal(false)
      # ssh's warning lines don't launder real remote stderr through the rule.
      Krikri::SSHManager.connection_level_failure?(255, "Warning: Permanently added '[127.0.0.1]:22991' (ED25519) to the list of known hosts.\nerror while loading shared libraries: libyaml-0.so.2\n", "").must_equal(false)
    end

    it "classifies ssh's own mid-session drop line (Connection closed by) as a connection failure" do
      # Live shape (2026-10-07, podman socket that accepts TCP and closes):
      # ssh prints "Connection closed by <ip> port <n>" and exits 255.
      # The words alone stay out of CONNECTION_FAILURE_PATTERNS (a remote
      # command's stderr can carry them) - the guarded tier requires
      # ssh's 255 exit and empty plugin stdout.
      Krikri::SSHManager.connection_level_failure?(255, "Connection closed by 127.0.0.1 port 22993\r\n", "").must_equal(true)
      Krikri::SSHManager.connection_level_failure?(255, "Connection reset by 127.0.0.1 port 22993\r\n", "").must_equal(true)
      Krikri::SSHManager.connection_level_failure?(255, "Connection reset by peer", "").must_equal(true)
    end

    it "keeps the mid-session drop guard one-sided against remote command output" do
      # Plugin produced output -> it ran; its stderr text (even
      # transport-adjacent) is its own, not the transport's.
      Krikri::SSHManager.connection_level_failure?(255, "Connection closed by 127.0.0.1 port 22993\r\n", "some plugin output").must_equal(false)
      # A remote command's own ssh failure arrives inside the plugin's
      # JSON result (ssh exit 0) - the exit gate already keeps it out.
      Krikri::SSHManager.connection_level_failure?(0, "Connection closed by 10.0.0.1 port 22", "").must_equal(false)
      # Non-255 exits never enter either guarded tier.
      Krikri::SSHManager.connection_level_failure?(3, "Connection closed by 127.0.0.1 port 22993\r\n", "").must_equal(false)
    end
  end
end
