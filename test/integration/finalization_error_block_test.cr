require "../minitest_helper"
require "file_utils"

# Task-arg finalization failures on tasks WITHOUT a name: (the task origin is
# the module key line itself, so Ansible prints two levels), free-form command
# args reported as _raw_params, action-only modules without a `changed` key,
# and Python-typed attribute errors. Live-compared byte for byte with
# ansible-playbook 2.19.11 via scripts/output_parity.sh on the same playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (nameless tasks)" do
  it "prints the two-level block, _raw_params, typed attribute errors and omits changed for debug" do
    playbook = File.tempname("finalization-block", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          d: {a: 1}
        tasks:
          - ansible.builtin.debug:
              msg: "{{ d.a.b.c }}"
            ignore_errors: true
          - ansible.builtin.command: "echo {{ missing_var }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': object of type 'int' has no attribute 'b'")
    text.must_include("\nTask failed: Finalization of task args for 'ansible.builtin.debug' failed.\nOrigin: #{playbook}:6:7")
    text.must_include("<<< caused by >>>")
    text.must_include("Error while resolving value for 'msg': object of type 'int' has no attribute 'b'\nOrigin: #{playbook}:7:14")
    # action-only module: no changed key; Ansible module: changed false
    text.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Finalization of task args for 'ansible.builtin.debug' failed))
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.command' failed: Error while resolving value for '_raw_params': 'missing_var' is undefined"}))
    # only ONE block per failure (the result display no longer adds a second)
    text.scan("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug'").size.must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
