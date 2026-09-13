require "../spec_helper"
require "../../src/krikri/plugin_manager"

# Round 601090 (robertdebock.common warm rerun): a dead host's dispatch
# results reached TaskExecutor as a bare `_connection_failure` marker
# with no way to tell "the SSH transport never connected" apart from
# "the remote plugin crashed". interpret_remote_result now stamps
# `unreachable: true` on exactly the former (via
# SSHManager.connection_level_failure?'s single shared pattern list) -
# that stamp is what TaskExecutor's facts/task booking paths key on.
describe Krikri::PluginManager do
  describe ".interpret_remote_result" do
    it "stamps unreachable on an SSH transport failure" do
      result = Krikri::PluginManager.interpret_remote_result(
        255, "",
        "ssh: connect to host 10.99.10.2 port 22: No route to host"
      )
      result["failed"].as_bool.should be_true
      result["_connection_failure"].as_bool.should be_true
      result["unreachable"].as_bool.should be_true
    end

    it "keeps a remote plugin crash a plain failure" do
      result = Krikri::PluginManager.interpret_remote_result(
        127, "",
        "/bin/bash: facts: command not found"
      )
      result["failed"].as_bool.should be_true
      result["_connection_failure"].as_bool.should be_true
      result["unreachable"]?.should be_nil
    end

    it "stamps nothing but the executor's failed/changed normalization on a successful parseable run" do
      result = Krikri::PluginManager.interpret_remote_result(0, %({"changed": false}), "")
      # The module wire result itself no longer carries failed: false
      # (real exit_json never emits the key) - this boundary is what
      # backfills it, mirroring task_executor._execute_internal.
      result["failed"]?.try(&.as_bool).should be_false
      result["unreachable"]?.should be_nil
    end

    it "backfills failed: true from a nonzero rc when the module omitted it" do
      result = Krikri::PluginManager.interpret_remote_result(0, %({"changed": false, "rc": 2}), "")
      result["failed"].as_bool.should be_true
    end
  end
end
