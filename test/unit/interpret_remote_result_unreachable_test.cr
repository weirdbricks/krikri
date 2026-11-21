require "../minitest_helper"
require "../../src/krikri/plugin_manager"

# Round 601090 (robertdebock.common warm rerun): a dead host's dispatch
# results reached TaskExecutor as a bare `_connection_failure` marker
# with no way to tell "the SSH transport never connected" apart from
# "the remote plugin crashed". interpret_remote_result now stamps
# `unreachable: true` on exactly the former (via
# SSHManager.connection_level_failure?'s single shared pattern list) -
# that stamp is what TaskExecutor's facts/task booking paths key on.
describe "Krikri::PluginManager (interpret_remote_result_unreachable_test.cr)" do
  describe ".interpret_remote_result" do
    it "stamps unreachable on an SSH transport failure" do
      result = Krikri::PluginManager.interpret_remote_result(
        255, "",
        "ssh: connect to host 10.99.10.2 port 22: No route to host"
      )
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"].as_bool.must_equal(true)
    end

    it "stamps unreachable on a silent mid-execution ssh death" do
      # Live-verified 2026-10-07: a server vanishing mid-execution with a
      # clean TCP close gives ssh exit 255 with empty stdout AND stderr -
      # ansible-playbook books UNREACHABLE for this, the engine used to
      # book a generic failed task.
      result = Krikri::PluginManager.interpret_remote_result(255, "", "")
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"].as_bool.must_equal(true)
    end

    it "stamps unreachable on ssh's own mid-session drop line" do
      result = Krikri::PluginManager.interpret_remote_result(255, "", "Connection closed by 127.0.0.1 port 22993\r\n")
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"].as_bool.must_equal(true)
    end

    it "stamps unreachable on a 255 wording outside the old pattern list (issue #1663)" do
      # The classification is the exit code, not ssh's words: any 255 ssh
      # gives is ansible's AnsibleConnectionFailure (see
      # SSHManager.connection_level_failure?). The third report of this
      # family came from macOS ssh wording this engine had never seen,
      # which reached users as a raw `fatal: FAILED!` payload with
      # failed=1 and exit 2.
      result = Krikri::PluginManager.interpret_remote_result(
        255, "",
        "Connection to 127.0.0.1 closed by remote host."
      )
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"].as_bool.must_equal(true)
    end

    it "keeps a 255 exit another program explains a plain failure" do
      # ansible's b_NOT_SSH_ERRORS: a remote-side traceback means the 255
      # came from the module, not from ssh.
      result = Krikri::PluginManager.interpret_remote_result(
        255, "", "Traceback (most recent call last):\n  File \"/tmp/x.py\", line 1\nNameError"
      )
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"]?.must_be_nil
    end

    it "keeps a silent nonzero remote plugin exit a plain failure" do
      result = Krikri::PluginManager.interpret_remote_result(137, "", "")
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"]?.must_be_nil
    end

    it "keeps a remote plugin crash a plain failure" do
      result = Krikri::PluginManager.interpret_remote_result(
        127, "",
        "/bin/bash: facts: command not found"
      )
      result["failed"].as_bool.must_equal(true)
      result["_connection_failure"].as_bool.must_equal(true)
      result["unreachable"]?.must_be_nil
    end

    it "stamps nothing but the executor's failed/changed normalization on a successful parseable run" do
      result = Krikri::PluginManager.interpret_remote_result(0, %({"changed": false}), "")
      # The module wire result itself no longer carries failed: false
      # (real exit_json never emits the key) - this boundary is what
      # backfills it, mirroring task_executor._execute_internal.
      result["failed"]?.try(&.as_bool).must_equal(false)
      result["unreachable"]?.must_be_nil
    end

    it "backfills failed: true from a nonzero rc when the module omitted it" do
      result = Krikri::PluginManager.interpret_remote_result(0, %({"changed": false, "rc": 2}), "")
      result["failed"].as_bool.must_equal(true)
    end
  end
end
