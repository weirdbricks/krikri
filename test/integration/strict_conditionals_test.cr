require "../minitest_helper"

# ansible-core 2.19 requires a conditional to end in a REAL boolean:
# `when: some_string`, `when: some_int`, `when: some_list` all fail the
# task with "Conditional result (X) was derived from value of type 'T'.
# Conditionals must have a boolean result." This engine used to apply
# Python-ish truthiness and run or skip instead - so a task Ansible
# refuses to decide at all silently took a branch here.
#
# Differentialed against ansible-core 2.19.4 over every shape below,
# including the ANSIBLE_ALLOW_BROKEN_CONDITIONALS escape hatch, which
# Ansible honours and this project's own benchmark harness has set
# on the real-Ansible side since round 20.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, env : Hash(String, String)? = nil)
  playbook = File.tempname("strict-conditionals", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, env: env)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def playbook_for(condition : String) : String
  <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    vars:
      s_false: "false"
      s_text: "hello"
      empty_str: ""
      n_one: 1
      real_bool: true
      my_list: [1, 2]
    tasks:
      - name: gated
        ansible.builtin.debug:
          msg: "TASK-RAN"
        when: #{condition}
  YAML
end

describe "strict boolean conditionals" do
  it "fails for a string-valued condition, naming the type and the derived result" do
    status, output = run_playbook(playbook_for("s_text"))

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'str'")
    output.must_include("Conditionals must have a boolean result")
    # The [ERROR] chain's Origin context quotes the playbook SOURCE
    # (Ansible's own chain does too); assert on the executed-task
    # display instead.
    output.wont_include("\"msg\": \"TASK-RAN\"")
  end

  # The case that silently diverged: this engine read "false" as false
  # and skipped, where Ansible refuses the conditional outright.
  it "fails for the string 'false' rather than quietly skipping" do
    status, output = run_playbook(playbook_for("s_false"))

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'str'")
  end

  it "reports (False) for an empty string" do
    status, output = run_playbook(playbook_for("empty_str"))

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'str'")
  end

  it "fails for an int-valued condition" do
    status, output = run_playbook(playbook_for("n_one"))

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'int'")
  end

  it "fails for a list-valued condition" do
    status, output = run_playbook(playbook_for("my_list"))

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'list'")
  end

  # adfinis-sygroup.network's `when: network_interfaces is defined and
  # network_interfaces` with the var defaulting to `[]` (round 84003):
  # the `and` chain's deciding operand is the list itself, so the whole
  # conditional's result is list-typed (Python's `and` returns the
  # operand, not a bool) - Ansible fails the task with the
  # "Task failed: " prefix this error class carries, not the generic
  # "Error while evaluating conditional: " wrapper an undefined
  # reference gets.
  it "fails an `X is defined and X` chain ending in a list as 'Task failed: ...' (round 84003)" do
    status, output = run_playbook(playbook_for("my_list is defined and my_list"))

    status.exit_code.must_equal(2)
    output.must_include("Task failed: Conditional result (True) was derived from value of type 'list'")
    output.must_include("Conditionals must have a boolean result")
    # The [ERROR] chain's Origin context quotes the playbook SOURCE
    # (Ansible's own chain does too); assert on the executed-task
    # display instead.
    output.wont_include("\"msg\": \"TASK-RAN\"")
  end

  it "accepts a genuine boolean" do
    status, output = run_playbook(playbook_for("real_bool"))

    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")
  end

  # Real boolean operators produce real booleans, so these keep working
  # untouched - the rule is about the RESULT's type, not the syntax.
  it "accepts comparisons, membership and defined-ness tests" do
    ["s_text == 'hello'", "s_text != 'x'", "1 in my_list", "s_text is defined",
     "s_text | length > 0", "my_list | length == 2"].each do |condition|
      status, output = run_playbook(playbook_for(condition))
      status.exit_code.must_equal(0)
      output.must_include("TASK-RAN")
    end

    # `not <string>` is a real boolean too - it just happens to be
    # false here, so the task is skipped rather than failed (verified
    # against Ansible, which skips it identically).
    status, output = run_playbook(playbook_for("not s_text"))
    status.exit_code.must_equal(0)
    output.wont_include("TASK-RAN")
  end

  it "relaxes to truthiness under ANSIBLE_ALLOW_BROKEN_CONDITIONALS" do
    env = {"ANSIBLE_ALLOW_BROKEN_CONDITIONALS" => "true"}

    status, output = run_playbook(playbook_for("s_text"), env)
    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")

    # ...including the falsy side: the task is skipped, not failed.
    status, output = run_playbook(playbook_for("s_false"), env)
    status.exit_code.must_equal(0)
    output.wont_include("TASK-RAN")
  end

  # Round 400022 (crazikpl.logging): a LIST-form when: is Ansible's
  # own sequence of INDEPENDENT conditionals, each type-checked
  # separately - `when: [(str or b2), b]` fails there ("Conditional
  # result (True) was derived from value of type 'str'") even though the
  # equivalent single-string `when: (str or b2) and b` PASSES (Python's
  # `and` returns the last operand, so only the whole expression's
  # result type is checked - verified live against 2.19.4 over both
  # shapes). Joining the list into one `and` string and strict-checking
  # only the JOINED result made the whole-file divergence: krikri ran
  # the role's tasks where ansible-playbook failed outright.
  it "type-checks each when: LIST item separately, like the single-string whole result" do
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          s_text: "hello"
          real_bool: true
        tasks:
          - name: gated
            ansible.builtin.debug:
              msg: "TASK-RAN"
            when:
              - s_text or real_bool
              - real_bool
      YAML

    status, output = run_playbook(yaml)
    status.exit_code.must_equal(2)
    output.must_include("Conditional result (True) was derived from value of type 'str'")
    output.must_include("Conditionals must have a boolean result")
    output.wont_include("TASK-RAN")
  end

  it "still accepts an all-boolean list-form when:" do
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          real_bool: true
          other_bool: false
        tasks:
          - name: gated
            ansible.builtin.debug:
              msg: "TASK-RAN"
            when:
              - real_bool
              - not other_bool
      YAML

    status, output = run_playbook(yaml)
    status.exit_code.must_equal(0)
    output.must_include("TASK-RAN")
  end

  it "short-circuits a false list item without evaluating later items" do
    # Same left-to-right short-circuit the " and "-joined string already
    # had - a false first item skips the task, and a later item that
    # would raise (here: an undefined reference) must never be reached.
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          real_bool: false
        tasks:
          - name: gated
            ansible.builtin.debug:
              msg: "TASK-RAN"
            when:
              - real_bool
              - never_defined_var
      YAML

    status, output = run_playbook(yaml)
    status.exit_code.must_equal(0)
    output.wont_include("TASK-RAN")
    output.wont_include("Error while evaluating conditional")
  end

  # Round 5300002 (kaos2oak.java): the role's `when: |-
  # lookup('env', 'JAVA_VERSION' ) is defined and lookup('env',
  # 'JAVA_VERSION' )` with the env var unset became a whole-conditional
  # result of "" (Python's `and` returns the deciding operand's own
  # value), so real 2.19.11 aborts the play with the strict
  # boolean-conditional error while this engine treated the string as
  # falsy and skipped - rc=0, failed=0. Verified live against 2.19.11 on
  # this machine; the failing value's lineage is a `lookup('env', X)`
  # result, whose origin real tracks as "<environment variable 'X'>"
  # (re-verified round 5310002) and is now part of the message.
  it "fails a bare lookup call resolving to a string, as the round 5300002 repro ends the play" do
    # The name is never set anywhere in the suite or the repo (grep-able),
    # and the suite spec env does not define it: `lookup('env', ...)` then
    # deterministically returns "".
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Set java_version from environment variable
            ansible.builtin.set_fact:
              java_version: "{{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_COND_STR_CALL_TEST' ) }}"
            when: |-
              lookup('env', 'CRYSTAL_ANSIBLE_SPEC_COND_STR_CALL_TEST' ) is defined and
              lookup('env', 'CRYSTAL_ANSIBLE_SPEC_COND_STR_CALL_TEST' )
    YAML

    status, output = run_playbook(yaml)
    status.exit_code.must_equal(2)
    output.must_include("Task failed: Conditional result (False) was derived from value of type 'str' at \"<environment variable 'CRYSTAL_ANSIBLE_SPEC_COND_STR_CALL_TEST'>\". Conditionals must have a boolean result.")
  end
end
