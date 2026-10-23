require "../minitest_helper"

# Issue #262: ansible-core 2.19 raises failed_when:/changed_when:'s strict
# conditional-type error at the check step, outside the conditional-
# evaluation trap, so the stored *_when_result text is NOT prefixed with
# "Error while evaluating conditional: " (live-verified vs 2.19.11, and
# contrasted with an undefined-reference evaluation error, which IS
# prefixed the same way on both engines) and the same data lineage when:
# already applies: a registered result / compound expression is labeled
# with the clause's own VALUE token (jgkim.atom's `failed_when:
# return_value.rc` -> tasks/main.yml:6:16), a defined variable with its
# definition site.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("failed-when-bool-origin", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "changed_when:/failed_when: strict boolean error lineage" do
  it "stores the drop-prefixed failed_when_result labeled at the failed_when value token" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: rc 1 reinterpreted through a plain failed_when
          ansible.builtin.command: /bin/false
          register: return_value
          failed_when: return_value.rc
    YAML

    status.exit_code.must_equal(2)
    # failed_when's value token sits on line 8, column 20 (counting the
    # six-space key indent, the 11-char key, its colon and one space).
    output.must_include(%("failed_when_result": "Conditional result (True) was derived from value of type 'int' at '#{playbook}:8:20'. Conditionals must have a boolean result."))
    output.wont_include("Error while evaluating conditional: Conditional result")
  end

  it "stores the same unprefixed changed_when_result labeled at the variable's definition" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        an_int: 1
      tasks:
        - name: debug ok with an int changed_when
          ansible.builtin.debug:
            msg: hello
          changed_when: an_int
          register: out
          ignore_errors: true
        - name: surface the stored text
          ansible.builtin.debug:
            msg: "{{ out.changed_when_result }}"
    YAML

    status.success?.must_equal(true)
    # an_int's definition value token: line 5, column 13. Surfaced through
    # a registered read because the console fatal dump (this engine AND
    # real 2.19.11) shows only the debug task's own msg for this shape.
    output.must_include(%("msg": "Conditional result (True) was derived from value of type 'int' at '#{playbook}:5:13'. Conditionals must have a boolean result."))
    output.wont_include("Error while evaluating conditional: Conditional result")
  end
end
