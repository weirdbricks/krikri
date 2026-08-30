require "../spec_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("assert-strict-boolean", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# assert:'s own that: must reject a non-bool result exactly as when: does
# ("Conditional result (True) was derived from value of type 'int'.
# Conditionals must have a boolean result."), prefixed "Task failed: "
# rather than when:'s own "Error while evaluating conditional: " prefix -
# both are ConditionalEvaluator::ConditionalBooleanError under the hood,
# but real ansible-core 2.19.4 reports them through different wrappers.
# Found via mrlesmithjr.postgresql's own preflight.yml: `that:
# postgresql_version | default(false)` where postgresql_version defaults
# to a real int (14) - real Ansible fails the whole play at this first
# task; this plugin previously called ConditionalEvaluator.evaluate
# without strict: true (only raise_undefined: true), so the nonzero int
# was silently treated as truthy and the play continued for 5 more
# tasks before diverging elsewhere.
describe "assert: strict-boolean that:" do
  it "rejects a non-bool (int) that: result as a task failure, not a pass" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          postgresql_version: 14
        tasks:
          - name: Ensure postgresql_version is not empty
            ansible.builtin.assert:
              that: postgresql_version | default(false)
      YAML

    status.success?.should be_false
    output.should contain("Task failed:")
    output.should contain("Conditional result (True) was derived from value of type 'int'")
    output.should_not contain("All assertions passed")
    output.should contain("failed=1")
  end

  it "still passes a genuine bool that: result" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          enabled: true
        tasks:
          - name: real bool passes
            ansible.builtin.assert:
              that: enabled
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
    output.should contain("failed=0")
  end
end
