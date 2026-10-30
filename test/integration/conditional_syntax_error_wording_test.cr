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

  # A when: LIST fails strict per CLAUSE, and real pins the chain's
  # "caused by" Origin on the failing item's LINE: the " and "-joined
  # string matches no item in the folded-list scan, so the whole chain
  # never printed (issue #330, constrict0r.desktop).
  it "pins a when: list's unknown-test chain at the failing item line" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Two checks
            debug: msg="x"
            when:
              - x is not variable_empty
              - x is variable_boolean_true
      YAML
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Syntax error in expression: No test named 'variable_empty'.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Syntax error in expression: No test named 'variable_empty'.\"}")
    output.must_include("<<< caused by >>>")
    # The cause stanza's Origin sits at the list ITEM line (playbook
    # lines 7-8, column of the clause text after "- "), not the when:
    # key: excerpt "7 when: / 8 - x is..." + caret under the item text.
    output.must_include("7 " + " " * 6 + "when:\n8 " + " " * 8 + "- x is not variable_empty\n" + " " * 12 + "^ column 11")
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

  # Ansible compiles conditionals as raw expressions - it never renders
  # `{{ }}` out of them - so a delimiter-bearing conditional outside any
  # string literal is its "Template delimiters are not supported in
  # expressions" syntax error (found via chriswayg.mailcow /
  # rockandska.rabbitmq's own assert preflights, rounds 1500413/1500208,
  # where this engine rendered the delimiters away and PASSED the task).
  it "fails a when: with embedded template delimiters, real wording" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug: msg="x"
            when: 1 >= {{ 1 }}
      YAML
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Syntax error in expression. Template delimiters are not supported in expressions: expected token ':', got '}'")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Syntax error in expression. Template delimiters are not supported in expressions: expected token ':', got '}'\"}")
    output.wont_include("Unhandled exception")
  end

  it "fails an assert: whose that: item carries template delimiters, real chain and changed=false" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Preflight
            assert:
              that:
                - 1 >= {{ 1 }}
      YAML
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Syntax error in expression. Template delimiters are not supported in expressions: expected token ':', got '}'")
    # two-level chain: task origin, then the failing that: item
    output.must_include("<<< caused by >>>")
    output.must_include("- 1 >= {{ 1 }}")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Syntax error in expression. Template delimiters are not supported in expressions: expected token ':', got '}'\"}")
    output.wont_include("Unhandled exception")
  end

  it "still accepts a whole-template conditional (deprecation only) and a quoted delimiter" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          some_flag: true
          expected: x
        tasks:
          - debug: msg="whole"
            when: "{{ some_flag }}"
          - debug: msg="quoted"
            when: "expected == '{{ expected }}'"
      YAML
    status.exit_code.must_equal(0)
    output.must_include("[DEPRECATION WARNING]: Conditionals should not be surrounded by templating delimiters")
    output.wont_include("Template delimiters are not supported")
  end

  # assert: evaluates `that:` items in order and stops at the first false
  # one, and real warns (the templating-delimiters deprecation, each with
  # its own Origin at the item's opening quote) for every item it
  # EVALUATED: all of them on a passing assert, only the evaluated prefix
  # on a failing one (issue #581). The folded item's Origin stays on its
  # first line.
  it "warns for each evaluated whole-template that: item, up to the failing one" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          supported: ['ubuntu']
        tasks:
          - name: All three items pass
            ansible.builtin.assert:
              that:
                - "{{ 'ubuntu' in supported }}"
                - "{{ '22.04' in ['22.04', '24.04'] }}"
                - "{{ 'x86_64' in ['x86_64'] }}"
              success_msg: passed

          - name: Second item fails, third never evaluated
            ansible.builtin.assert:
              that:
                - "{{ 'ubuntu' in supported }}"
                - "{{ 'centos' in supported }}"
                - "{{ 'x86_64' in ['x86_64'] }}"
              fail_msg: failed
            ignore_errors: true

          - name: Folded multi-line conditional with ternary
            ansible.builtin.assert:
              that:
                - "{{ (supported | first == 'ubuntu')
                  if 'ubuntu' in supported else supported | first == 'x' }}"
              success_msg: passed
      YAML
    status.exit_code.must_equal(0)
    warning = "[DEPRECATION WARNING]: Conditionals should not be surrounded by templating delimiters such as {{ }} or {% %}. This feature will be removed from ansible-core version 2.23."
    output.scan(warning).size.must_equal(6, output)
    origins = output.scan(/\[DEPRECATION WARNING\][^\n]*\nOrigin: [^\n]*\.yml:(\d+):(\d+)/)
    origins.size.must_equal(6, output)
    origins.map { |match| {match[1].to_i, match[2].to_i} }.must_equal(
      [{10, 13}, {11, 13}, {12, 13}, {18, 13}, {19, 13}, {27, 13}], output)
  end
end
