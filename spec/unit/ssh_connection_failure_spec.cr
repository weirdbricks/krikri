require "../spec_helper"
require "../../src/krikri/ssh_manager"

# Real bug found via round 601090 (robertdebock.common, kata backend,
# warm rerun): a host the cold run's reboot had killed came back as
# "ssh: connect to host ... No route to host" on every dispatch, and
# krikri booked each one as a generic "Plugin execution failed on
# remote" FAILED task while real ansible-playbook booked UNREACHABLE
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
describe Krikri::SSHManager do
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
      }.each do |stderr|
        Krikri::SSHManager.connection_level_failure?(255, stderr).should be_true, "#{stderr.inspect} should classify as a connection-level failure"
      end
    end

    it "recognizes krikri's own synthesized transport-failure shapes" do
      {
        "SSH command timed out after 3600s (host likely unreachable) and did not exit even after being killed",
        "SSH execution failed: Broken pipe",
        "SSH script execution failed: Broken pipe",
      }.each do |stderr|
        Krikri::SSHManager.connection_level_failure?(255, stderr).should be_true
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
        Krikri::SSHManager.connection_level_failure?(127, stderr).should be_false, "#{stderr.inspect} should NOT classify as a connection-level failure"
      end
    end

    it "does not classify a successful run even with transport-shaped text in stderr" do
      # A remote command's own output can mention transport-adjacent
      # text (e.g. a curl timing out); exit 0 means the transport was
      # fine, so the exit-code gate wins.
      Krikri::SSHManager.connection_level_failure?(0, "ssh: connect to host 10.0.0.1 port 22: Connection timed out").should be_false
    end

    it "does not match a bare transport-adjacent phrase without ssh's own prefix" do
      # The conservative direction: a remote curl/nc's stderr can carry
      # "Connection timed out"/"Connection refused" on its own; only
      # ssh's own "ssh: connect to host ..." prefix is evidence of the
      # transport dying.
      Krikri::SSHManager.connection_level_failure?(7, "curl: (7) Failed to connect to 10.0.0.1 port 80: Connection refused").should be_false
      Krikri::SSHManager.connection_level_failure?(7, "nc: connect to 10.0.0.1 port 22 (tcp) failed: Connection timed out").should be_false
    end
  end
end
