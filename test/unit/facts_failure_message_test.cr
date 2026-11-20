require "../minitest_helper"
require "../../src/krikri/task_executor/executor_facts_register"

# Issue #1659 (follow-up to #1543): a second run whose changed ssh_args
# break the connection fails the implicit Gathering Facts task at the
# transport level, but with a warm plugin-state cache no upload
# verification round trip runs first, so the failure arrives here as
# interpret_remote_result's generic "Plugin execution failed on remote"
# msg with ssh's own error kept in stderr. ansible-playbook reports that
# ssh error in the UNREACHABLE msg ("... Make sure this host can be
# reached over ssh: Connection closed by UNKNOWN port 65535"), and
# report_unreachable wraps whatever detail this message carries - so the
# generic msg must never be what a transport-unreachable gather returns.
describe "Krikri::TaskExecutor.facts_failure_message (facts_failure_message_test.cr)" do
  it "reports ssh's own stderr instead of the generic msg for an unreachable gather" do
    result = JSON.parse({
      "changed"             => false,
      "failed"              => true,
      "msg"                 => "Plugin execution failed on remote",
      "stderr"              => "Connection closed by UNKNOWN port 65535\r\n",
      "_connection_failure" => true,
      "unreachable"         => true,
    }.to_json)

    Krikri::TaskExecutor.facts_failure_message(result)
      .must_equal("Connection closed by UNKNOWN port 65535")
  end

  it "keeps the generic msg for an unreachable gather with no stderr to show" do
    # ssh's silent mid-execution death (exit 255, both streams empty) has
    # no detail of its own; ansible falls back to the connection host, so
    # an empty string must not replace the msg here.
    result = JSON.parse({
      "changed"     => false,
      "failed"      => true,
      "msg"         => "Plugin execution failed on remote",
      "stderr"      => "",
      "unreachable" => true,
    }.to_json)

    Krikri::TaskExecutor.facts_failure_message(result)
      .must_equal("Plugin execution failed on remote")
  end

  it "still appends the plugin's stderr to a module-level gather failure" do
    result = JSON.parse({
      "changed" => false,
      "failed"  => true,
      "msg"     => "Plugin execution failed on remote",
      "stderr"  => "error while loading shared libraries: libxml2.so.2: cannot open shared object file",
    }.to_json)

    Krikri::TaskExecutor.facts_failure_message(result)
      .must_equal("Plugin execution failed on remote\n  stderr: error while loading shared libraries: libxml2.so.2: cannot open shared object file")
  end
end
