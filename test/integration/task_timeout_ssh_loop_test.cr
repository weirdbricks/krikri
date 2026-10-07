require "../minitest_helper"

require "socket"

# The task-level `timeout:` deadline on the REMOTE (ssh) path, for LOOPED
# tasks specifically - the gap Atlantic round 3100000 found on the real
# hosts (kop_task_timeout probe, `loop: [1, 30]` with `timeout: 4` over
# `shell: sleep {{ item }}; echo ok`):
#
#   - pre-fix krikri sent the whole loop through ONE shared SSH round trip
#     (execute_looped_task_batched), so the per-item deadline was
#     unenforceable: the `sleep 30` item ran to completion and printed
#     `changed` (krikri cold wall 49.9 s vs real 24.2 s);
#   - real (ansible-core 2.19.11) sets a FRESH SIGALRM per item -
#     TaskExecutor._run_loop calls _execute per item and the alarm wraps
#     only that item's handler.run (task_executor.py:621) - so the item
#     that outlives `timeout:` fails with
#     "Task failed: Timed out after N second(s)." while faster items pass.
#
# The fix routes a `timeout:` looped task through the one-at-a-time path,
# whose per-item dispatch carries the deadline
# (execute_task_once -> PluginManager.execute_plugin -> the remote
# exec_script deadline kill), so each item gets its own full budget -
# exactly real's shape. On a fast transport the sub-budget item(s) pass
# and the over-budget item(s) fail; the per-item pass/fail SPLIT depends
# on each item's real execution time, which is why the assertions below
# pin the over-budget item's failure, the under-budget item's success
# (sleep 1 against a 4 s budget, over a loopback SSH link), and that the
# over-budget item is NEVER reported `changed`.
#
# The run must also be BOUNDED: pre-fix, the `sleep 30` item ran to
# completion over SSH (~30 s extra wall clock); post-fix the deadline
# kill caps it near the 4 s budget.
#
# This spec needs a real sshd reachable from the controller - the dev
# box has none, so it skips there. One throwaway server, as used to
# verify this fix (adjust the key path/port to match):
#
#   ssh-keygen -t ed25519 -N '' -f /tmp/kkt-key
#   podman run -d --name kkt-sshd -p 127.0.0.1:2224:22 ubuntu:22.04 \
#     sh -c 'while :; do sleep 3600; done'
#   podman exec kkt-sshd bash -c 'apt-get update \
#     && apt-get install -y openssh-server python3 \
#     && mkdir -p /root/.ssh && chmod 700 /root/.ssh'
#   podman cp /tmp/kkt-key.pub kkt-sshd:/root/.ssh/authorized_keys
#   podman exec kkt-sshd ssh-keygen -A
#   podman exec -d kkt-sshd /usr/sbin/sshd -D
#
# The same shape runs against any sshd reachable at
# KRIKRI_TEST_SSHD_HOST/PORT with KRIKRI_TEST_SSHD_KEY authorized for
# KRIKRI_TEST_SSHD_USER.

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

private def run_over_ssh(playbook_body : Array(String)) : {Process::Status, String, Time::Span}
  playbook = PluginSpecHelper.tmp_path("task-timeout-ssh-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, playbook_body.join("\n") + "\n")
  inventory = PluginSpecHelper.tmp_path("task-timeout-ssh-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'\n")
  output = IO::Memory.new
  started = Time.instant
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
  {status, output.to_s, Time.instant - started}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(inventory) if inventory && File.exists?(inventory)
end

describe "task timeout keyword over ssh (loop batching exclusion)" do
  it "enforces the deadline per loop item on the remote path" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    status, output, elapsed = run_over_ssh([
      "- hosts: target",
      "  gather_facts: false",
      "  tasks:",
      "    - name: loop slow",
      "      ansible.builtin.shell: \"sleep {{ item }}; echo ok\"",
      "      loop: [1, 30]",
      "      timeout: 4",
      "      ignore_errors: true",
    ])

    status.success?.must_equal(true)
    # The under-budget item passes (sleep 1 against a 4 s budget)...
    output.includes?("changed: [target] => (item=1)").must_equal(true, output)
    # ...and the over-budget item fails with real's exact per-item shape
    # (captured from 2.19.11 over SSH, Atlantic round 3100000):
    output.includes?("failed: [target] (item=30) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": 30, \"msg\": \"Task failed: Timed out after 4 second(s).\", \"timedout\": {\"frame\": \"Configure `DISPLAY_TRACEBACK` to see a traceback on timeout errors.\", \"period\": 4}}").must_equal(true, output)
    output.includes?("changed: [target] => (item=30)").must_equal(false, output)
    output.includes?("...ignoring").must_equal(true, output)
    # The deadline kill must bound the run: pre-fix the 30 s item ran to
    # completion (one shared SSH round trip, no deadline at all).
    # Generous ceiling so a slow CI box never trips it - the point is
    # "not 30+ seconds", not a precise measurement.
    (elapsed < 20.seconds).must_equal(true, "run took #{elapsed.total_seconds}s - the sleep 30 item was not deadline-killed")
  end
end
