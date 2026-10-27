require "../minitest_helper"

# Runs the compiled binary against a real playbook: the prefix decision
# happens in the executor's finalization and task-NAME display paths, not
# in the evaluator itself, so only the full binary shows the real output.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "template operator TypeError prefix in task output" do
  it "prefixes operand-type failures with Error rendering template in name marker, args and fatal msg" do
    # Real ansible-core 2.19.11 reports a Python operator TypeError
    # (null + 'str' here) as "Error rendering template: <msg>" in the
    # task-NAME marker, the args finalization line and the fatal msg,
    # while leaving an undefined NAME bare (next test).
    playbook = File.tempname("operand-type-prefix", ".yml")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          sap_hana_installdir:
        tasks:
          - name: Check availability of "{{ sap_hana_installdir + '/hdblcm' }}"
            ansible.builtin.stat:
              path: "{{ sap_hana_installdir + '/hdblcm' }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    text.must_include("<< error 1 - Error rendering template: unsupported operand type(s) for +: 'NoneType' and 'str' >>")
    text.must_include("Error while resolving value for 'path': Error rendering template: unsupported operand type(s) for +: 'NoneType' and 'str'")
    text.must_include(%("msg": "Task failed: Finalization of task args for 'ansible.builtin.stat' failed: Error while resolving value for 'path': Error rendering template: unsupported operand type(s) for +: 'NoneType' and 'str'"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "leaves an undefined name bare in the args finalization error" do
    # An undefined NAME combined with an operator is still just
    # "'undef_v' is undefined" - no "Error rendering template: " prefix
    # (live-verified vs real 2.19.11).
    playbook = File.tempname("operand-type-undef", ".yml")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: check
            ansible.builtin.stat:
              path: "{{ undef_v + '/hdblcm' }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    text.must_include("Error while resolving value for 'path': 'undef_v' is undefined")
    text.wont_include("Error rendering template")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
