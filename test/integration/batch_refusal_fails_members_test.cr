require "../minitest_helper"

require "socket"

# A batch script that refuses to run BEFORE any step (the staging-safety
# refusals exit 75) must FAIL its group's members, not silently skip them -
# 0xRedpoll.ludus_mythic_teamserver (issue #834, round 29896654) showed the
# full shape on real hosts. The role's Mythic clone + build filled the
# microvm's small disk mid-run; the next batch group's script then could not
# create its batch dir (`mkdir "$D"` fails, the owner check that follows
# reads an empty stat output), refused with exit 75 - and krikri reported
# all seventeen remaining tasks as bare `skipping:` lines (recap skipped=19,
# run exit 0) where real Ansible, one ssh round trip per task, fails the
# task in flight (its own temporary-directory creation fails the same way)
# and halts the host. The refusal is reproduced here at the batch dir
# itself: `batch` pre-created as a regular file trips the script's very
# first check (`[ -e "$P" ] && ! [ -d "$P" ]` -> exit 75) - the same
# zero-results-nonzero-exit shape a full disk produces.
#
# This spec needs a real sshd reachable from the controller (batching only
# engages off the local connection) - it skips without one. The same
# throwaway server task_timeout_ssh_loop_test.cr's header documents works;
# override KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY to point elsewhere.
#
# --no-persistent-daemon is passed deliberately: the daemon transport
# serves an eligible group without ever running the batch script, so the
# refusal (and the silent-skip bug) only exists on the script transport -
# which is also what served the round (the daemon was not up on the fresh
# microvm yet, and a failed daemon request falls back to the script).

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

private def ssh_exec(command : String) : {Bool, String}
  io = IO::Memory.new
  status = Process.run("ssh", ["-o", "StrictHostKeyChecking=no",
                               "-o", "UserKnownHostsFile=/dev/null", "-o", "IdentitiesOnly=yes",
                               "-i", SSHD_KEY, "-o", "ConnectTimeout=5", "-p", SSHD_PORT.to_s,
                               "#{SSHD_USER}@#{SSHD_HOST}", command], output: io, error: Process::Redirect::Close)
  {status.success?, io.to_s.strip}
end

describe "a refusing batch script fails its members instead of skipping them (issue #834)" do
  it "fails the group's first member with the refusal evidence and never reports skipping" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    # The batch parent carries the connecting user's staging tag; cleaning
    # by glob keeps the test independent of its exact hash (and of earlier
    # runs' leftovers, which would otherwise trip OTHER sshd tests' own
    # batches).
    ssh_exec("rm -rf /var/tmp/.krikri-playbook-*/batch /tmp/krikri-834-refusal-marker")
    ssh_exec("mkdir -p /var/tmp/.krikri-playbook-root-dc76e9f0 && touch /var/tmp/.krikri-playbook-root-dc76e9f0/batch")

    playbook = PluginSpecHelper.tmp_path("batch-refusal-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, [
      "- hosts: target",
      "  gather_facts: false",
      "  tasks:",
      "    - name: member A (side-effect probe)",
      "      ansible.builtin.command: touch /tmp/krikri-834-refusal-marker",
      "    - name: member B",
      "      ansible.builtin.command: echo B",
      "    - name: member C",
      "      ansible.builtin.command: echo C",
      "",
    ].join("\n"))
    inventory = PluginSpecHelper.tmp_path("batch-refusal-#{Random::Secure.hex(4)}.ini")
    File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")

    output = IO::Memory.new
    status = Process.run(BINARY, ["--no-persistent-daemon", "-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
    run_out = output.to_s

    # The refusal must be LOUD: a failed run (real Ansible fails the task
    # in flight), the refusal's own stderr surfaced in the fatal's JSON,
    # exactly one fatal for the host (the members after the failed one
    # stay silent, like real's post-failure tasks) - and NOT a single
    # bare `skipping:` line, which is precisely what pre-fix krikri
    # printed for every member while exiting 0.
    status.success?.must_equal(false, run_out)
    run_out.includes?("krikri batch dir parent is not a directory").must_equal(true, run_out)
    run_out.includes?("skipping: [target]").must_equal(false, "the refused batch's members were silently skipped:\n#{run_out}")
    run_out.scan(/fatal: \[target\]/).size.must_equal(1, run_out)

    # And nothing may have actually run on the target: the refusal aborts
    # before any step, so even member A's touch never happened.
    ran, _ = ssh_exec("test -e /tmp/krikri-834-refusal-marker")
    ran.must_equal(false, "a batch member executed despite the script's refusal")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(inventory) if inventory && File.exists?(inventory)
    # Leave the shared sshd clean: the batch file would trip every other
    # sshd test's own batch scripts otherwise.
    ssh_exec("rm -rf /var/tmp/.krikri-playbook-*/batch /tmp/krikri-834-refusal-marker")
  end
end
