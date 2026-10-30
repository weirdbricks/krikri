require "../minitest_helper"
require "../../src/krikri/plugin_manager"

# The task-end remote tmpdir cleanup's verdict (issue #400,
# aguamala.reboot-and-wait-for): Ansible ends every non-async remote module
# task with a `rm -f -r <tmpdir>` exec made right after the module's result
# came back, and an exception out of that cleanup - raised from the attempt
# loop's `finally` - REPLACES the module's own result. A connection-level
# failure there books the task UNREACHABLE with the ssh transport's own
# stderr ("Failed to connect to the host via ssh: ..."), the host dropped
# from the rest of the play and the run exiting 4 - which is how a task
# whose module ran just before the host took its own ssh session down
# (`command: shutdown -r now`) fatal's in real instead of reporting changed
# and letting the play run on. krikri's module result used to stand alone
# (no post-result connection attempt ever happened), so the same playbook
# exited 2 with the play continuing into the role's wait_for task.
describe "Krikri::PluginManager task_end_cleanup_failure_result (task_end_cleanup_test.cr)" do
  describe ".task_end_cleanup_failure_result" do
    it "replaces a successful module result with the unreachable shape when the cleanup exec's transport died" do
      module_result = JSON.parse({"changed" => true, "rc" => 0, "stdout" => ""}.to_json)
      # ssh's own connect failure through a resetting forward - the exact
      # stderr shape real's cleanup exec produced on the issue's hosts.
      cleanup = {exit_code: 255, stdout: "", stderr: "kex_exchange_identification: read: Connection reset by peer\r\nConnection reset by 192.0.2.10 port 2222\r\n"}
      result = Krikri::PluginManager.task_end_cleanup_failure_result(module_result, cleanup)
      result["unreachable"].as_bool?.must_equal(true)
      result["changed"].as_bool?.must_equal(false)
      result["msg"].as_s?.must_equal("Failed to connect to the host via ssh: kex_exchange_identification: read: Connection reset by peer\r\nConnection reset by 192.0.2.10 port 2222")
      result["stderr"].as_s?.must_equal("kex_exchange_identification: read: Connection reset by peer\r\nConnection reset by 192.0.2.10 port 2222")
    end

    it "also replaces a FAILED module result - the finally-raised exception wins over any module outcome" do
      module_result = JSON.parse({"changed" => false, "failed" => true, "rc" => 1, "msg" => "boom"}.to_json)
      cleanup = {exit_code: 255, stdout: "", stderr: "Connection reset by 192.0.2.10 port 2222\r\n"}
      result = Krikri::PluginManager.task_end_cleanup_failure_result(module_result, cleanup)
      result["unreachable"].as_bool?.must_equal(true)
      # The canonical transport-unreachable wire shape (the one
      # interpret_remote_result stamps): failed rides along so
      # result_failed_flag readers (the Gathering Facts booking) never
      # read a transport death back as a successful task.
      result["failed"].as_bool?.must_equal(true)
    end

    it "keeps the module's own result when the cleanup exec succeeded" do
      module_result = JSON.parse({"changed" => true, "rc" => 0}.to_json)
      cleanup = {exit_code: 0, stdout: "", stderr: ""}
      Krikri::PluginManager.task_end_cleanup_failure_result(module_result, cleanup).must_equal(module_result)
    end

    it "keeps the module's own result when the cleanup exec failed but not at the transport level" do
      module_result = JSON.parse({"changed" => false, "failed" => true, "rc" => 1}.to_json)
      # a remote command crash's stderr names the remote failure, never the
      # transport - the same discrimination interpret_remote_result applies
      cleanup = {exit_code: 2, stdout: "", stderr: "rm: some remote shell error"}
      Krikri::PluginManager.task_end_cleanup_failure_result(module_result, cleanup).must_equal(module_result)
    end

    it "falls back to a bare detail when the transport failure carried no text" do
      module_result = JSON.parse({"changed" => true, "rc" => 0}.to_json)
      # bare 255 with nothing in either stream is ssh's own mid-execution
      # death (the silent-transport-death rule) - the ssh stderr is empty
      cleanup = {exit_code: 255, stdout: "", stderr: ""}
      result = Krikri::PluginManager.task_end_cleanup_failure_result(module_result, cleanup)
      result["unreachable"].as_bool?.must_equal(true)
      result["msg"].as_s?.must_equal("Failed to connect to the host via ssh: connection lost")
    end
  end
end
