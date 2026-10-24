require "../minitest_helper"

# Issue #313: a looped task whose when: raises a conditional error must print
# ansible-core 2.19's two-level "[ERROR]: Task failed:" chain block ONCE,
# before the per-item "failed: (item=X)" lines. The one-at-a-time path had
# this via execute_task_once's own WhenEvaluationError rescue; the BATCHED
# loop path (remote hosts) never emitted it, so its output lacked the block
# entirely.
#
# The batched loop path is only reachable for a NON-local host
# (loop_batch_eligible? excludes local connections), so this uses the
# inventory-nonlocal-host.ini fixture - safe without a real sshd, because a
# failing when: aborts every item during the batch's per-item pre-check and
# a looped debug: never opens an SSH connection.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-nonlocal-host.ini")

describe "looped batched path when: error chain block" do
  it "prints the chain block once, before the per-item failed lines" do
    playbook = File.tempname("loop-batched-when-chain", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: batchhost
        gather_facts: false
        vars:
          user_groups: [a, b]
        tasks:
          - name: looped when raises
            ansible.builtin.debug:
              msg: "hello {{ item }}"
            loop: "{{ user_groups }}"
            when: user_groups
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    text = output.to_s
    status.exit_code.must_equal(2)
    chain = "[ERROR]: Task failed: Conditional result (True) was derived from value of type 'list'"
    text.must_include(chain, text)
    # Both items raise the SAME message text through the same rescue: the
    # chain's per-text dedup must keep the block to one (Ansible's Display
    # does the same for its per-loop ReducerError).
    text.scan(chain).size.must_equal(1)
    chain_idx = text.index!(chain)
    failed_idx = text.index!("failed: [batchhost] (item=a) =>")
    (chain_idx < failed_idx).must_equal(true, text)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
