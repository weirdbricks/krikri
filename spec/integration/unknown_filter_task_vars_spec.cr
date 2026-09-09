require "../spec_helper"

# Runs the compiled binary against a real playbook - an unknown filter
# inside a task's OWN `vars:` block surfaces in TaskExecutor#build_vars_
# context (render_task_vars re-raises it), not in the main task-body
# param substitution whose rescue already degrades cleanly, so only a
# live TaskExecutor run can prove the process survives it.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "unknown filter in a task's own vars: block" do
  # nephelaiio.pip / nephelaiio.gitlab's own `nephelaiio.plugins.sorted_get`
  # inside a set_fact task's vars: block: krikri detected the unknown filter
  # and raised the right error, but nothing between render_task_vars and
  # krikri-playbook's top-level run caught it, so the whole process crashed
  # with an unhandled Crystal exception. Real ansible-playbook fails just
  # that task ("No filter named 'X'.") and recaps failed=1.
  it "fails the task cleanly instead of crashing the whole process" do
    playbook = File.tempname("unknown-filter-task-vars", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: task with unknown filter in its own vars
            ansible.builtin.debug:
              msg: should never print
            vars:
              sorted: "{{ 'abc' | nephelaiio.plugins.sortedget }}"
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("No filter named 'nephelaiio.plugins.sortedget'.")
    output.to_s.should contain("failed=1")
  end
end
