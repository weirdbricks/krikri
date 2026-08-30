require "../spec_helper"

# Runs the compiled binary against a real playbook, since this bug is
# specifically about TaskExecutor#run_task_list (the single-host nested
# block/rescue/always dispatch path), a private method not reachable from
# a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a named block: nested inside another block:" do
  it "prints no banner of its own, only its members' - matching real Ansible" do
    # Real bug found benchmarking prometheus.prometheus.alertmanager round
    # 134: run_task_list (used for block_tasks/rescue_tasks/always_tasks on
    # the single-host path) printed a "TASK [...]" banner unconditionally
    # for every nested task, including a nested task that was itself a
    # named block: - producing a spurious extra banner with no output
    # under it before the block's real children ran. run_task_batch (the
    # multi-host counterpart) already special-cased task.block? to skip
    # straight to execute_block without printing its own banner; this path
    # lacked the same guard.
    playbook = File.tempname("nested-block-banner", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: outer block
            block:
              - name: inner named block
                block:
                  - name: leaf task
                    ansible.builtin.debug:
                      msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    text = output.to_s
    text.should_not contain("TASK [inner named block]")
    text.should contain("TASK [leaf task]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
