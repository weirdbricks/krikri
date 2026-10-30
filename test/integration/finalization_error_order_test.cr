require "../minitest_helper"
require "socket"

# The [ERROR]: Task failed: ... chain block for a task-arg FINALIZATION
# failure must print under the FAILING task's own banner, just before its
# fatal line (ansible-core 2.19.11's ordering). The batch path
# (execute_batch_group) prepares every member of an SSH round trip up
# front, so an inline print there surfaced the block one task early -
# under the PREVIOUS task's header, ahead of that task's changed: line
# (issue #14, pylabs.nginx's `upgrade system` / `setup hostname` pair).
# The block now rides the failed result and prints at display time.
#
# Ordering is only observable in the combined 2>&1 stream of a run where
# the failing task shares a batch group with a preceding task over a real
# (non-local) connection - batching skips local connections entirely, so
# this needs a live sshd, like task_timeout_ssh_loop_test.cr. It skips on
# the dev box; set KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY (same throwaway
# podman sshd that file's header documents) to run it.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private SSHD_HOST = ENV["KRIKRI_TEST_SSHD_HOST"]? || "127.0.0.1"
private SSHD_PORT = (ENV["KRIKRI_TEST_SSHD_PORT"]? || "2224").to_i
private SSHD_USER = ENV["KRIKRI_TEST_SSHD_USER"]? || "root"
private SSHD_KEY  = ENV["KRIKRI_TEST_SSHD_KEY"]? || "/tmp/kkt-key"

# Checks a path on the test target over the same plain ssh the transport
# itself uses; rc 0 means the file exists there.
private def remote_test(path : String) : Bool
  Process.run("/bin/sh", ["-c", "ssh -i #{SSHD_KEY.inspect} -p #{SSHD_PORT} -o IdentitiesOnly=yes " \
                                "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 " \
                                "#{SSHD_USER}@#{SSHD_HOST} 'test -e #{path.inspect}'"]).exit_code == 0
end

private def sshd_reachable? : Bool
  return false unless File.exists?(SSHD_KEY)
  TCPSocket.new(SSHD_HOST, SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

# Runs the playbook with stderr duped onto stdout INSIDE the child
# (`2>&1` via sh -c), so the captured stream preserves the exact write
# order - two separate pipes drained by the parent can interleave
# arbitrarily and would hide (or fake) exactly the ordering this pins.
# Both fds land in one file, so the file's byte order IS the write order.
private def run_combined(playbook : String, inventory : String) : {Process::Status, String}
  combined = File.tempname("finalization-order", ".out")
  File.open(combined, "w") do |file|
    status = Process.run("/bin/sh", ["-c", "#{BINARY.inspect} -i #{inventory.inspect} #{playbook.inspect} 2>&1"],
      output: file, input: Process::Redirect::Close)
    {status, File.read(combined)}
  end
ensure
  File.delete(combined) if combined && File.exists?(combined)
end

describe "finalization error block output ordering (batch path)" do
  it "prints the [ERROR] block under the failing task's banner, after the previous task's changed line" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    dir = PluginSpecHelper.tmp_path("finalization-order-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - name: upgrade system
            ansible.builtin.command: /bin/true

          - name: setup hostname
            ansible.builtin.command: '{{ sysbase_hostname }}'
      YAML
    inventory = File.join(dir, "inv.ini")
    File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'\n")

    status, output = run_combined(playbook, inventory)
    output = output.gsub(/\e\[[0-9;]*m/, "")

    status.exit_code.must_equal(2)
    error_idx = output.index("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.command'")
    banner2_idx = output.index("TASK [setup hostname]")
    changed_idx = output.index("changed: [target]")
    fatal_idx = output.index("fatal: [target]: FAILED!")

    changed_idx.wont_be_nil
    banner2_idx.wont_be_nil
    error_idx.wont_be_nil
    fatal_idx.wont_be_nil
    # The regression: pre-fix the block printed between the FIRST task's
    # banner and its changed: line (during batch-build, before any result
    # displayed). It must come after the changed: line and under the
    # failing task's own banner, just before the fatal line.
    (changed_idx.not_nil! < banner2_idx.not_nil!).must_equal(true, output)
    (banner2_idx.not_nil! < error_idx.not_nil!).must_equal(true, output)
    (error_idx.not_nil! < fatal_idx.not_nil!).must_equal(true, output)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # A batch member whose when: raises is a FAILED task, so Ansible aborts
  # the play there and its later group members never touch the target.
  # execute_batch_group cached the failed result and continued building, so
  # the round trip still dispatched the later members: tumf.docker-compose's
  # `when: ver|failed` compile error failed Remove Old Version, yet the same
  # group's Install Docker Compose get_url ran anyway and left a real
  # docker-compose binary on the host - invisible in that run's byte-identical
  # output, but the next (warm) phase then stat-ed a file ansible's host
  # never had (issue #649: skipping vs ok on Check Docker Compose version).
  # Only a live sshd shows this: local connections never batch.
  it "does not dispatch a batch group's later members to the target after a member's when: fails to evaluate" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    dir = PluginSpecHelper.tmp_path("batch-when-halt-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    marker = "/tmp/krikri649-#{Random::Secure.hex(4)}"
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - name: earlier member
            ansible.builtin.command: /bin/true

          - name: broken conditional
            ansible.builtin.command: /bin/true
            when: broken_register|failed

          - name: never-reached member
            ansible.builtin.shell: touch #{marker}
      YAML
    inventory = File.join(dir, "inv.ini")
    File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")

    status, output = run_combined(playbook, inventory)
    output = output.gsub(/\e\[[0-9;]*m/, "")

    status.exit_code.must_equal(2)
    output.must_include("fatal: [target]: FAILED!")
    output.must_include("No filter named 'failed'")
    # The consumer stops at the fatal, so no banner for the third task - but
    # the regression was what the TARGET saw, not what was printed.
    output.wont_include("TASK [never-reached member]")
    remote_test(marker).must_equal(false, "broken-conditional task aborted the play, " \
                                          "but a later batch member still ran on the target:\n#{output}")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
