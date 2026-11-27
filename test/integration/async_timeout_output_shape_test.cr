require "../minitest_helper"

require "socket"

# Regression for issue #1463: a polled async task whose budget runs out has
# TWO possible ansible-core outcomes, and krikri reported neither - it
# invented its own "async task did not complete within N seconds".
#
#  - local connection: the poll that reaches the async budget runs just
#    before async_wrapper's own timer would write its record, so
#    task_executor synthesizes the failure from a poll result it never
#    parsed. Real reports "async task produced unparsable results", nests
#    the last poll under async_result, and (that synthesis carrying no
#    ErrorSummary) prints no [ERROR] block and registers no exception.
#  - over SSH: the extra round trip loses that race to async_wrapper's
#    timer, so the last poll sees the wrapper's FINISHED timeout record -
#    "Timeout exceeded" plus the child_pid it killed, merged into the
#    async_status base dict (started/finished/stdout/stderr/results_file).
#
# Both shapes were captured live against ansible-core 2.21.6 with the issue's
# own `async: 2, poll: 1` playbook (the remote one against the throwaway
# sshd the other ssh specs use - see task_timeout_ssh_loop_test.cr's header).
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

private def run_async_timeout_playbook(inventory : String, host : String) : String
  home = PluginSpecHelper.tmp_path("home")
  Dir.mkdir_p(home)
  playbook = PluginSpecHelper.tmp_path("async-timeout.yml")
  File.write(playbook, <<-YAML)
    - hosts: #{host}
      gather_facts: false
      tasks:
        - ansible.builtin.command: sleep 10
          async: 2
          poll: 1
          ignore_errors: true
          register: r
        - ansible.builtin.debug: {var: r}
    YAML
  output = IO::Memory.new
  Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, env: {"HOME" => home})
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def local_inventory : String
  path = PluginSpecHelper.tmp_path("async-timeout-local.ini")
  File.write(path, "[local]\nlocalhost ansible_connection=local\n")
  path
end

describe "async timeout output shape" do
  it "reports the synthesized unparsable-results failure on a local connection" do
    output = run_async_timeout_playbook(local_inventory, "localhost")

    output.must_match(/ASYNC FAILED on localhost: jid=(j\S+)/)
    output.must_include(%("msg": "async task produced unparsable results"))
    output.wont_include("async task did not complete")
    # The synthesized failure nests the still-running stub under
    # async_result, with the async_status base keys the next poll carried.
    output.must_include(%("async_result": {))
    output.must_include(%("finished": false))
    output.must_include(%("started": true))
    output.must_match(/"results_file": "[^"]*\/\.ansible_async\/#{Regex.escape(output[/ASYNC FAILED on localhost: jid=(j\S+)/, 1])}"/)
    # No ErrorSummary behind a synthesized failure: real prints no [ERROR]
    # block and registers no exception key for this one.
    output.wont_include("[ERROR]: Task failed: Module failed: async task")
    output.wont_include(%("exception":))
  end

  it "kills a poll:0 job at its async budget and records it" do
    # Issue #1899: async_wrapper's timer runs on the target whether or not
    # anyone polls, so a fire-and-forget job must not outlive async: - the
    # reboot idiom `sleep 2 && shutdown -r now` with `async: 1, poll: 0`
    # never reaches its shutdown under real ansible, and a host that really
    # rebooted there made the next phase's first connection unreachable.
    home = PluginSpecHelper.tmp_path("home")
    Dir.mkdir_p(home)
    marker = File.join(home, "poked")
    playbook = PluginSpecHelper.tmp_path("async-poll0.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.shell: sleep 3 && echo done > "#{marker}"
            async: 1
            poll: 0
          - ansible.builtin.wait_for: {timeout: 4}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", local_inventory, playbook], output: output, error: output, env: {"HOME" => home})
    File.exists?(marker).must_equal(false)
    # The job file holds async_wrapper's own timeout record, which is what a
    # later async_status: reads; it carries no "finished" key because the
    # record's appearance IS the completion (AsyncJobs.finished?).
    records = Dir.children(File.join(home, ".ansible_async")).reject(&.ends_with?(".config.json"))
    records.size.must_equal(1)
    File.read(File.join(home, ".ansible_async", records.first)).must_include(%("msg":"Timeout exceeded"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "reports the wrapper's Timeout exceeded record over ssh" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless sshd_reachable?

    inventory = PluginSpecHelper.tmp_path("async-timeout-ssh.ini")
    # IdentitiesOnly=yes keeps a desktop session's ssh-agent keys from
    # exhausting the throwaway sshd's MaxAuthTries (same reason
    # task_timeout_ssh_loop_test.cr pins it).
    File.write(inventory, "[remote]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'\n")

    output = run_async_timeout_playbook(inventory, "target")

    output.must_match(/ASYNC FAILED on target: jid=(j\S+)/)
    output.must_include(%("msg": "Timeout exceeded"))
    output.wont_include("async task did not complete")
    output.wont_include("async task produced unparsable results")
    # The async_status base dict survives, and the wrapper's own record
    # names the pid it timed out.
    output.must_include(%("finished": true))
    output.must_include(%("started": true))
    output.must_include(%("stdout": ""))
    output.must_include(%("stderr": ""))
    output.must_match(/"child_pid": \d+/)
    # A real timeout record is a parsed module failure, so the register
    # carries ansible's exception placeholder.
    output.must_include(%("exception": "(traceback unavailable)"))
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
  end
end
