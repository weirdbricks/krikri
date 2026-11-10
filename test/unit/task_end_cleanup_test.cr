require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/connection_settings"
require "../../src/krikri/host"
require "../../src/krikri/shell"

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

  # Issue #1086 (SoInteractive.sshd, benchmark round 29905183): Ansible's
  # `_remove_tmp_path` runs over the connection the module just used, so a
  # role that closes the host to NEW logins while the established session
  # keeps working (that role writes `PermitRootLogin no` and restarts sshd
  # from a handler) still finishes rc 0 in real. The cleanup exec used to
  # pass `fresh_connection: true` (`ControlPath=none`, a real end-to-end
  # dial), so the very next exec re-authenticated - `root@host: Permission
  # denied` - and the handler's successful `changed` became UNREACHABLE,
  # dropping the host and exiting 4.
  describe "PluginManager task_end_remote_cleanup connection choice (task_end_cleanup_test.cr)" do
    serial! # prepends a fake `ssh` to the process-wide PATH

    it "rides the task's pooled ControlMaster instead of dialing its own connection" do
      shim_dir = PluginSpecHelper.tmp_path("fake-ssh-task-end-cleanup")
      argv_log = PluginSpecHelper.tmp_path("fake-ssh-task-end-cleanup-argv")
      FileUtils.rm_r(shim_dir) if File.exists?(shim_dir)
      File.delete(argv_log) if File.exists?(argv_log)
      Dir.mkdir_p(shim_dir)
      # One line per invocation: its argv, space-joined.
      File.write("#{shim_dir}/ssh", "#!/bin/sh\necho \"$*\" >> #{Krikri::Shell.single_quote(argv_log)}\nexit 0\n")
      File.chmod("#{shim_dir}/ssh", 0o755)

      host = Krikri::Host.new("testhost", "root", 2222)
      host.vars = {
        "ansible_host"                 => JSON::Any.new("192.0.2.10"),
        "ansible_ssh_private_key_file" => JSON::Any.new("/keys/id_ed25519"),
        "ansible_ssh_common_args"      => JSON::Any.new("-o IdentitiesOnly=yes"),
      } of String => JSON::Any
      conn = Krikri::ConnectionSettings.resolve(host, host.vars)

      PluginSpecHelper::ENV_MUTEX.synchronize do
        old_path = ENV["PATH"]?
        ENV["PATH"] = "#{shim_dir}:#{old_path}"
        begin
          2.times { Krikri::PluginManager.task_end_remote_cleanup(conn) }
        ensure
          old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
        end
      end

      invocations = File.read(argv_log).lines.reject(&.empty?)
      invocations.size.must_equal(2)
      control_paths = invocations.map do |line|
        line.split(' ').find { |arg| arg.starts_with?("ControlPath=") }
      end
      control_paths.each do |path|
        # `ControlPath=none` is OpenSSH's own spelling for "dial a brand
        # new connection" - the exact argv that broke #1086.
        path.to_s.starts_with?("ControlPath=#{Krikri::SSHManager.control_path_dir}/").must_equal(true)
      end
      # ... and the same pooled socket both times, so a second cleanup (or
      # the next task) never re-authenticates either.
      control_paths.uniq.size.must_equal(1)
      invocations.each do |line|
        line.includes?("rm -f -r ~/.ansible/tmp/ansible-tmp-").must_equal(true)
      end
    end
  end
end
