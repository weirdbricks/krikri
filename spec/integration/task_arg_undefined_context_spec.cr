require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Real Ansible's task-arg templating failure for a strict-undefined
# module argument is NOT the bare inner error text - it wraps it ("The
# task includes an option with an undefined variable. The error was:
# <text>. <text>" - the doubled copy is real's own message+orig_exc
# concatenation) and appends its AnsibleError-obj context: the
# offending task's source location from the playbook YAML plus the
# surrounding lines with a caret. Live-captured from real ansible-core
# 2.14 via testing/podman-diff/cases/set_fact_edge_cases.yml (S1).
describe "task-arg undefined-variable failure message" do
  it "wraps the inner error and appends the task's source-location context" do
    playbook = File.tempname("task-arg-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: "S1 set_fact referencing an undefined variable"
            ansible.builtin.set_fact:
              derived_fact: "{{ undefined_source_var }}-suffix"
            register: s1
            ignore_errors: true
          - name: echo result
            ansible.builtin.debug:
              msg: "R {{ s1.msg | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    out = output.to_s
    out.should contain("The task includes an option with an undefined variable. The error was: 'undefined_source_var' is undefined. 'undefined_source_var' is undefined")
    out.should contain("The error appears to be in '#{File.expand_path(playbook)}': line 5, column 7")
    out.should contain("The offending line appears to be:")
    out.should contain("- name: \"S1 set_fact referencing an undefined variable\"")
    out.should contain("^ here")
    # ... and the registered var's msg carries the same wrapped text,
    # not just the task-display path.
    out.should contain("R The task includes an option with an undefined variable. The error was:")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
