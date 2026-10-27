require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

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
# but ansible-core 2.19.4 reports them through different wrappers.
# Found via mrlesmithjr.postgresql's own preflight.yml: `that:
# postgresql_version | default(false)` where postgresql_version defaults
# to a real int (14) - Ansible fails the whole play at this first
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

    status.success?.must_equal(false)
    output.must_include("Task failed:")
    output.must_include("Conditional result (True) was derived from value of type 'int'")
    output.wont_include("All assertions passed")
    output.must_include("failed=1")
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

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
    output.must_include("failed=0")
  end

  # Real 2.19 also labels the non-bool fatal msg with the tested value's
  # DEFINING site (" at '<file>:<line>:<col>'" - the same data-lineage
  # clause the when: path prints) and wraps the failure in the two-level
  # [ERROR] chain: "Task failed." at the task's name, "<<< caused by >>>"
  # with the conditional message again at the failing that: item's own
  # Origin, then the ALLOW_BROKEN_CONDITIONALS hint (live-verified vs
  # ansible-playbook 2.19.11). A dotted `name.key` item points at the
  # nested key's VALUE token in the file that supplies `name` - for the
  # play-vars shape below, the `pass:` line of the playbook itself.
  it "labels a non-bool dotted that: item with its defining site and prints the failure chain" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          dict_var:
            pass: ''
        tasks:
          - name: Dict attr check
            ansible.builtin.assert:
              that:
                - dict_var.pass
      YAML

    status.success?.must_equal(false)
    output.must_match(/Conditional result \(False\) was derived from value of type 'str' at '[^']+:\d+:\d+'\. Conditionals must have a boolean result\./)
    output.must_include("Task failed.")
    output.must_include("<<< caused by >>>")
    output.must_include("Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.")
    output.must_include("failed=1")
  end

  it "labels a non-bool bare-var that: item with the var's defining site" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          flag: ''
        tasks:
          - name: Bare var check
            ansible.builtin.assert:
              that:
                - flag
      YAML

    status.success?.must_equal(false)
    output.must_match(/Conditional result \(False\) was derived from value of type 'str' at '[^']+:\d+:\d+'\. Conditionals must have a boolean result\./)
    output.must_include("Task failed.")
    output.must_include("<<< caused by >>>")
    output.must_include("failed=1")
  end
end
