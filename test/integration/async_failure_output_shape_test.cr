require "../minitest_helper"

require "socket"

# Regression for issue #1397 (stancel.restore_bareos_backup's "Restore
# backup": `async: 1800, poll: 10` on a shell command that exits 1). A
# polled async job that ends in FAILURE is reported by ansible-playbook in
# two halves krikri was missing:
#
#  - the "ASYNC FAILED on <host>: jid=<jid>" default-callback line, printed
#    after the poll ticks and BEFORE the task's own error block
#    (callback/default.py's v2_runner_on_async_failed) - krikri only ever
#    printed the OK half;
#  - on the REMOTE (ssh) path, the async_status ACTION plugin's own base
#    dict (started, finished, stdout, stderr, stdout_lines, stderr_lines,
#    ansible_job_id, results_file) merged into the job file's module result.
#    The remote poll returned the raw job file, so the fatal: dump was short
#    those four keys (live-captured: `fatal: ... => {"ansible_job_id": ...,
#    "finished": true, "results_file": "/root/.ansible_async/<jid>",
#    "started": true, ...}`).
#
# The local case pins the callback line (and the still-correct wrapped
# shape) and needs no sshd. The remote case pins both halves against the
# throwaway sshd the other ssh specs use - see
# task_timeout_ssh_loop_test.cr's header for its setup.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private SSHD_HOST = ENV["KRIKRI_TEST_SSHD_HOST"]? || "127.0.0.1"
private SSHD_PORT = (ENV["KRIKRI_TEST_SSHD_PORT"]? || "2224").to_i
private SSHD_USER = ENV["KRIKRI_TEST_SSHD_USER"]? || "root"
private SSHD_KEY  = ENV["KRIKRI_TEST_SSHD_KEY"]? || "/tmp/kkt-key"

private def sshd_reachable? : Bool
  return false unless File.exists?(SSHD_KEY)
  TCPSocket.new(SSHD_HOST, SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

# A per-test HOME keeps this spec's job files out of the host-wide
# ~/.ansible_async that the async unit specs and other integration workers
# also touch; it is returned so the remote case can prove the reported
# results_file is the TARGET's path and not the controller's.
private def run_async_failure_playbook(inventory : String, host : String) : {Process::Status, String, String}
  home = PluginSpecHelper.tmp_path("home")
  Dir.mkdir_p(home)
  playbook = PluginSpecHelper.tmp_path("async-failure.yml")
  File.write(playbook, <<-YAML)
    - hosts: #{host}
      gather_facts: false
      tasks:
        - name: failing async job
          ansible.builtin.shell: "echo out; echo err >&2; exit 1"
          async: 60
          poll: 1
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, env: {"HOME" => home})
  {status, output.to_s, home}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def local_inventory : String
  path = PluginSpecHelper.tmp_path("async-failure-local.ini")
  File.write(path, "[local]\nlocalhost ansible_connection=local\n")
  path
end

describe "async job failure output" do
  it "prints ASYNC FAILED and the wrapped result for a local polled failure" do
    status, output, _home = run_async_failure_playbook(local_inventory, "localhost")

    status.success?.must_equal(false, output)
    output.must_match(/ASYNC FAILED on localhost: jid=(j\S+)/)
    output.wont_match(/ASYNC OK on localhost/)
    # ansible's async_status base dict: a failed polled job still reports
    # started/finished/ansible_job_id/results_file alongside the module's
    # own keys - the jid must be the one the ASYNC FAILED line named.
    jid = output[/ASYNC FAILED on localhost: jid=(j\S+)/, 1]
    output.must_include(%("ansible_job_id": "#{jid}"))
    output.must_include(%("finished": true))
    output.must_include(%("started": true))
    output.must_match(/"results_file": "[^"]*\/\.ansible_async\/#{Regex.escape(jid)}"/)
  end

  it "wraps a finished remote async job's result and prints ASYNC FAILED" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless sshd_reachable?

    inventory = PluginSpecHelper.tmp_path("async-failure-ssh.ini")
    # IdentitiesOnly=yes keeps a desktop session's ssh-agent keys from
    # exhausting the throwaway sshd's MaxAuthTries before this spec's own
    # key is offered (same reason task_timeout_ssh_loop_test.cr pins it).
    File.write(inventory, "[remote]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'\n")

    status, output, home = run_async_failure_playbook(inventory, "target")

    status.success?.must_equal(false, output)
    output.must_match(/ASYNC FAILED on target: jid=(j\S+)/)
    jid = output[/ASYNC FAILED on target: jid=(j\S+)/, 1]
    # The whole async_status base dict has to survive onto the remote
    # result, with results_file pointing at the TARGET's async dir (the
    # shell's own ~ expansion there), not the controller's.
    output.must_include(%("ansible_job_id": "#{jid}"))
    output.must_include(%("finished": true))
    output.must_include(%("started": true))
    output.must_match(/"results_file": "\/[^"]*\/\.ansible_async\/#{Regex.escape(jid)}"/)
    output.wont_include("#{home}/.ansible_async")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
  end
end
