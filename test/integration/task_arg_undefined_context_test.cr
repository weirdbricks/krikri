require "../minitest_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real Ansible's task-arg templating failure for a strict-undefined
# module argument (live-captured from real ansible-core 2.19.11,
# replacing the 2.14-era "The task includes an option with an undefined
# variable ..." wording): the fatal msg is
# "Task failed: Finalization of task args for '<module>' failed: Error
# while resolving value for '<key>': '<var>' is undefined", and BEFORE
# the fatal line real prints an [ERROR]: chain block - three levels,
# each with its own Origin at the playbook YAML (file:line:column, two
# context lines, caret under the value start) and "<<< caused by >>>"
# between them. The registered var's msg carries the same wrapped text.
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

    status.success?.must_equal(true)
    out = output.to_s
    out.must_include("Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'derived_fact': 'undefined_source_var' is undefined")
    out.must_include("Origin: #{File.expand_path(playbook)}:5:7")
    out.must_include("Origin: #{File.expand_path(playbook)}:7:23")
    out.must_include("<<< caused by >>>")
    out.must_include("^ column 7")
    out.must_include("^ column 23")
    # ... and the registered var's msg carries the same wrapped text,
    # not just the task-display path.
    out.must_include("R Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed:")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
