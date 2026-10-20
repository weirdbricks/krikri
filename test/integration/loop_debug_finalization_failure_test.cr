require "../minitest_helper"
require "file_utils"

# A looped debug: whose module arg references an undefined name fails each
# item at "Finalization of task args"; ansible prints the per-item line
# msg-only (no ansible_loop_var/item) and closes the loop with the aggregate
# fatal (issue #148, djarbz.proxmox_backup_client).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "looped debug arg finalization failure (loop_debug_finalization_failure_test.cr)" do
  it "prints msg-only item lines and the aggregate fatal" do
    playbook = File.tempname("loop-debug-final", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "{{ item }} {{ proxmox_backup.x }}"
            loop: [1, 2]
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    text.must_include("failed: [localhost] (item=1) => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed:")
    text.wont_include("ansible_loop_var")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"One or more items failed\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
