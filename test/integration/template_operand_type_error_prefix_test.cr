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

  it "fails a ternary's ordering comparison through the finalization chain" do
    # PeterMosmans.ansible-role-letsencrypt's own first task compares
    # `ansible_distribution_version|int >= '14.04'`, which is Python's
    # "'>=' not supported between instances of 'int' and 'str'" TypeError.
    # Real ansible-core 2.19.11 fails it as a full three-stanza
    # finalization chain (task name, module key, then the failing value's
    # own token), never the bare TypeError text (live-verified).
    playbook = File.tempname("ordering-type-ternary", ".yml")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          ansible_distribution: Ubuntu
          ansible_distribution_version: "24.04"
        tasks:
          - name: Use correct Python virtual environment package name
            set_fact: virtual_env="{{ 'virtualenv' if (((ansible_distribution == 'Debian') and (ansible_distribution_version >= '8')) or ((ansible_distribution == 'Ubuntu') and (ansible_distribution_version|int >= '14.04'))) else 'python-virtualenv' }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    inner = "Error while resolving value for 'virtual_env': Error rendering template: '>=' not supported between instances of 'int' and 'str'"
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: #{inner}")
    text.must_include("Task failed.\nOrigin: #{playbook}:8:7")
    text.must_include("Finalization of task args for 'ansible.builtin.set_fact' failed.\nOrigin: #{playbook}:9:7")
    text.must_include("#{inner}\nOrigin: #{playbook}:9:17")
    text.must_include(%("msg": "Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: #{inner}"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prefixes a direct string-vs-number comparison with Error rendering template" do
    # A top-level `'abc' >= 5` (no ternary) reaches the comparison
    # evaluator's own TypeError class instead; ansible 2.19.11 words it
    # identically, inside the same finalization chain (live-verified).
    playbook = File.tempname("ordering-type-direct", ".yml")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: comparison
            set_fact: x="{{ 'abc' >= 5 }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    inner = "Error while resolving value for 'x': Error rendering template: '>=' not supported between instances of 'str' and 'int'"
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: #{inner}")
    text.must_include("#{inner}\nOrigin: #{playbook}:6:17")
    text.must_include(%("msg": "Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: #{inner}"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
