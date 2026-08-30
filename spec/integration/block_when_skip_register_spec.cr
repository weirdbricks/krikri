require "../spec_helper"

# Runs the compiled binary against a real playbook, since this bug is
# specifically about TaskExecutor#print_skipped_tasks (block-level when:
# skip path), a private method not reachable from a unit spec without
# constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "register: on a task skipped via its enclosing block's when:" do
  it "still sets the variable to a skipped/changed:false result, overwriting an earlier register under the same name" do
    # Real bug found benchmarking robertdebock.tailscale round 134: a task
    # with its OWN when: false correctly re-registers via when_passes? ->
    # register_skip_result, but a task skipped only because its enclosing
    # block's when: was false went through the separate print_skipped_tasks
    # path, which never called register_skip_result - so a later task's
    # when: kept referencing whatever a PRIOR sibling block's task had
    # registered under the same name, instead of the (skipped) current
    # value. Real ansible-playbook always re-registers, even on skip.
    playbook = File.tempname("block-when-skip-register", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: block that runs
            when: true
            block:
              - name: sets shared_result changed
                ansible.builtin.command: echo first
                register: shared_result

          - name: block that is skipped
            when: false
            block:
              - name: would set shared_result unchanged
                ansible.builtin.command: echo second
                register: shared_result

          - name: only if shared_result still changed
            ansible.builtin.debug:
              msg: "shared_result.changed is {{ shared_result.changed }}"
            when: shared_result.changed
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("skipping:")
    output.to_s.should_not contain("shared_result.changed is")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
