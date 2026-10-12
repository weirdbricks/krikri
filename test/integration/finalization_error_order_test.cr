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
end
