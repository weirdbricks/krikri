require "../minitest_helper"

require "socket"

# A batch group's members are ALL prepared (and their real step results
# applied) before any of their banners' results display. When a later
# member's changed_when:/failed_when: raises against a result its
# preparation produced, krikri used to emit that member's clause-labelled
# [ERROR] chain right there - ahead of the earlier member's own result,
# and even when the earlier member's failure halted the play so real
# Ansible never reached the later one at all. jgkim.dotfiles' first task
# fails on a host with no git; its second task's `warn:` argspec failure
# plus `changed_when: ...stdout...` then printed a bogus chain no Ansible
# transcript contains (issue #1764).
#
# The chain still has to appear under the later member's own banner when
# the play DOES reach it, so both directions are asserted here.
#
# This spec needs a real sshd reachable from the controller (batching only
# engages off the local connection) - it skips without one. The same
# throwaway server task_timeout_ssh_loop_test.cr's header documents works;
# override KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY to point elsewhere.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private CLAUSE       = "A 'changed_when' expression failed"

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

# A src+content conflict is rejected controller-side while the group is
# being built, so the member itself never reaches the target - the same
# class of controller-side failure a `warn:`-rejecting command task hits.
private def run_batch_playbook(tasks : Array(String)) : {Process::Status, String}
  playbook = PluginSpecHelper.tmp_path("batch-clause-block-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, (["- hosts: target", "  gather_facts: false", "  tasks:"] + tasks).join("\n") + "\n")
  inventory = PluginSpecHelper.tmp_path("batch-clause-block-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(inventory) if inventory && File.exists?(inventory)
end

describe "a batch member's raising changed_when: chain waits for its own banner (issue #1764)" do
  it "does not print a later member's clause chain when an earlier member fails" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    status, run_out = run_batch_playbook([
      "    - name: earlier member fails",
      "      ansible.builtin.command: /nonexistent-binary-for-issue-1764",
      "    - name: later member is never reached",
      "      ansible.builtin.copy:",
      "        content: hello",
      "        src: /etc/hostname",
      "        dest: /tmp/krikri-1764-never-written",
      "      register: return_value",
      "      changed_when: \"return_value.stdout.find('up to date') == -1\"",
    ])

    status.success?.must_equal(false, run_out)
    run_out.includes?("earlier member fails").must_equal(true, run_out)
    # The later member's clause chain must not exist at all: real never
    # reaches that task, so its transcript has no such block.
    run_out.includes?(CLAUSE).must_equal(false, "printed a clause chain real never shows:\n#{run_out}")
    run_out.includes?("later member is never reached").must_equal(false, run_out)
    run_out.scan(/fatal: \[target\]/).size.must_equal(1, run_out)
  end

  it "prints the clause chain under the member's own banner when the play reaches it" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    status, run_out = run_batch_playbook([
      "    - name: earlier member succeeds",
      "      ansible.builtin.command: \"true\"",
      "    - name: later member fails its clause",
      "      ansible.builtin.copy:",
      "        content: hello",
      "        src: /etc/hostname",
      "        dest: /tmp/krikri-1764-never-written",
      "      register: return_value",
      "      changed_when: \"return_value.stdout.find('up to date') == -1\"",
    ])

    status.success?.must_equal(false, run_out)
    earlier_changed = run_out.index!("changed: [target]")
    later_banner = run_out.index!("TASK [later member fails its clause]")
    clause = run_out.index!(CLAUSE)
    (earlier_changed < later_banner).must_equal(true, run_out)
    (later_banner < clause).must_equal(true, run_out)
  end
end
