require "../minitest_helper"

require "socket"

# A batch-group member whose `when:` RAISES must halt the whole group, not
# just fail itself - xanmanning.helm (issue #663, round 29884720) made the
# WARM-vs-cold divergence visible on the real hosts:
#
#   - cold: the install-helm group's "Ensure helm_projects_dir exists"
#     member raised on a broken conditional (`when: helm_projects_dir is
#     defined and helm_projects_dir` - a str value), the play failed right
#     there, but the group's later mkdir/unarchive/copy/link steps still
#     executed in the same SSH round trip - the host ended up with the
#     helm binary installed even though the run reported failed=1;
#   - warm: the role's `when: helm_check_existing.stat.exists` then saw a
#     binary real Ansible never had (real halts the play before any of
#     those steps run), so krikri ran "Check Helm binary version if binary
#     already exists" (ok) while real skipped it.
#
# So the observable pre-fix bug is a REAL side effect on the target that
# follows a task failure - asserted here via the marker file the later
# group member would create.
#
# This spec needs a real sshd reachable from the controller (batching only
# engages off the local connection) - it skips without one. The same
# throwaway server task_timeout_ssh_loop_test.cr's header documents works;
# override KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY to point elsewhere.

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

describe "batch group halts when a member's when: raises (issue #663)" do
  it "does not run later group members after a member's when: evaluation fails" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    scratch = "/tmp/krikri-663-batch-halt-#{Random::Secure.hex(4)}"
    ssh_exec("rm -rf #{scratch}")

    playbook = PluginSpecHelper.tmp_path("batch-when-halt-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, [
      "- hosts: target",
      "  gather_facts: false",
      "  vars:",
      "    not_a_bool: \"hello\"",
      "  tasks:",
      "    - name: create scratch dir",
      "      ansible.builtin.file:",
      "        path: #{scratch}/dir",
      "        state: directory",
      "    - name: broken conditional member",
      "      ansible.builtin.file:",
      "        path: #{scratch}/dir",
      "        state: touch",
      "      when: not_a_bool",
      "    - name: later member must never run",
      "      ansible.builtin.command:",
      "        cmd: touch #{scratch}/marker",
      "",
    ].join("\n"))
    inventory = PluginSpecHelper.tmp_path("batch-when-halt-#{Random::Secure.hex(4)}.ini")
    File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
    run_out = output.to_s

    # The broken-conditional member itself still fails the play, exactly
    # like real (the conditional's strict str verdict).
    status.success?.must_equal(false, run_out)
    run_out.includes?("Conditionals must have a boolean result").must_equal(true, run_out)

    # The group's later member must never have executed: pre-fix it ran in
    # the same round trip and left the marker behind on the failed host.
    ran, _ = ssh_exec("test -e #{scratch}/marker")
    ran.must_equal(false, "later batch member ran after a member's when: failed")

    ssh_exec("rm -rf #{scratch}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(inventory) if inventory && File.exists?(inventory)
  end
end
