require "../spec_helper"

# `x is version_compare(min, '>=')` - real Ansible's older alias for the
# `version` test, still accepted by ansible-core 2.19.12 (verified live,
# round173, Rocky 9.6: the same playbook recaps ok=1 failed=0 there).
#
# ConditionalEvaluator only recognized `is version(...)`, so
# `version_compare` fell through to the generic comparison splitter,
# which mistook the `>=` INSIDE the quoted operator argument for a real
# comparison operator. That was silently benign while conditionals were
# lenient (it just evaluated false); once 0.9.548 made a bare undefined
# reference RAISE, the same misparse started hard-failing the task with
# "Error while evaluating conditional: '')' is undefined" - breaking the
# single most common version-gate idiom in real roles.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("version-compare", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "version_compare test alias" do
  it "evaluates version_compare() like version(), for literal and variable arguments" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: version with var arg
            ansible.builtin.debug: {msg: "A-ran"}
            when: ansible_version.string is version(minver, '>=')
          - name: version_compare with literal arg
            ansible.builtin.debug: {msg: "C-ran"}
            when: ansible_version.string is version_compare('2.11', '>=')
          - name: version_compare with var arg
            ansible.builtin.debug: {msg: "D-ran"}
            when: ansible_version.string is version_compare(minver, '>=')
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should contain("A-ran")
    output.should contain("C-ran")
    output.should contain("D-ran")
    output.should contain("failed=0")
  end

  # The compare-to argument was only ever unquoted, never resolved, so a
  # VARIABLE argument was version-compared as its own literal name.
  # Live-verified against ansible-core 2.19.12 (round173): identical
  # ok=2 skipped=1 for this playbook on both engines.
  it "resolves a variable compare-to argument instead of comparing its name" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: var compare-to, true branch
            ansible.builtin.debug: {msg: "VAR-ARG-TRUE"}
            when: ansible_version.string is version(minver, '>=')
          - name: var compare-to, false branch
            ansible.builtin.debug: {msg: "SHOULD-NOT-PRINT"}
            when: ansible_version.string is version(minver, '<')
      YAML

    status.success?.should be_true
    output.should contain("VAR-ARG-TRUE")
    output.should_not contain("SHOULD-NOT-PRINT")
    output.should contain("skipped=1")
  end

  it "works inside an assert: that: as well" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: version gate via assert
            ansible.builtin.assert:
              that:
                - ansible_version.string is version_compare(minver, '>=')
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should contain("failed=0")
  end
end
