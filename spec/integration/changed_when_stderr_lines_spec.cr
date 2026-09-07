require "../spec_helper"

# Runs the compiled binary against a real playbook: apply_changed_failed_when
# (executor_run_loop.cr) is a private method not reachable from a unit spec
# without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "changed_when:/failed_when: referencing the task's own stdout_lines/stderr_lines" do
  it "sees stdout_lines/stderr_lines on its OWN task's result, not just a later task's" do
    # Real bug found benchmarking buluma.netdata/mrlesmithjr.netdata:
    # register_result (executor_task_exec.cr) adds stdout_lines/
    # stderr_lines to the registered var for LATER tasks to see, but
    # apply_changed_failed_when built its own eval_context from the raw,
    # un-augmented plugin result - a changed_when:/failed_when: on the
    # SAME task referencing "<register>.stderr_lines" crashed with
    # "object of type 'dict' has no attribute 'stderr_lines'" even though
    # a later task referencing the identical registered var worked fine.
    playbook = File.tempname("changed-when-stderr-lines", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: install deps
            ansible.builtin.shell: echo "already installed" 1>&2
            register: install_result
            changed_when: "install_result.stderr_lines[0] == 'already installed'"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("undefined")
    output.to_s.should contain("changed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
