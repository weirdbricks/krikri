require "../minitest_helper"

# A compile-time-rejected filter or test name in a conditional is
# ansible-core 2.19's "Syntax error in expression: No filter/test named
# 'X'." failure class - Jinja's compiler rejects the name when it
# COMPILES the whole template, so it is a different wording (and no
# ALLOW_BROKEN_CONDITIONALS hint) from both the undefined-reference
# ("Error while evaluating conditional: ...") and the non-bool-result
# ("Conditional result ... Conditionals must have a boolean result.")
# classes. Live-compared byte for byte with ansible-playbook 2.19.11.
#
# Found via adarnimrod.apache (round 1200248): ca-store's Assertions
# preflight uses `version_compare` (removed from modern ansible-core),
# and krikri's assert: path raised the UnknownFilterError UNCAUGHT -
# the whole process crashed with a stack trace where Ansible fails the
# single task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("syntax-error-conditional", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unknown filter/test in conditionals: Syntax error in expression" do
  it "fails a when: with an unknown filter, real wording, chain block, no hint" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          release: focal
        tasks:
          - debug: msg="x"
            when: "ansible_os_family == 'Debian' and release | version_compare('5.7', '>=')"
      YAML
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Syntax error in expression: No filter named 'version_compare'.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Syntax error in expression: No filter named 'version_compare'.\"}")
    output.wont_include("Error while evaluating conditional")
    output.wont_include("ALLOW_BROKEN_CONDITIONALS")
    output.wont_include("Unhandled exception")
  end

  it "fails a when: with an unknown test the same way" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug: msg="x"
            when: "my_var is list"
      YAML
    status.exit_code.must_equal(2)
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Syntax error in expression: No test named 'list'.\"}")
    output.wont_include("ALLOW_BROKEN_CONDITIONALS")
    output.wont_include("Unhandled exception")
  end

  it "fails an assert: with an unknown filter instead of crashing" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Assertions
            assert:
              that:
                - "release | version_compare('5.7', '>=')"
      YAML
    status.exit_code.must_equal(2)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Syntax error in expression: No filter named 'version_compare'.\"}")
    # the two-level chain: task origin, then the failing that: item
    output.must_include("Task failed.")
    output.must_include("Syntax error in expression: No filter named 'version_compare'.\nOrigin: ")
    output.wont_include("Unhandled exception")
  end

  it "keeps the ALLOW_BROKEN_CONDITIONALS hint for the non-bool class" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          my_list: [1]
        tasks:
          - debug: msg="x"
            when: "my_list"
      YAML
    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'list'")
    output.must_include("ALLOW_BROKEN_CONDITIONALS")
  end
end
