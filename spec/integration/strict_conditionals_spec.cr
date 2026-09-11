require "../spec_helper"

# ansible-core 2.19 requires a conditional to end in a REAL boolean:
# `when: some_string`, `when: some_int`, `when: some_list` all fail the
# task with "Conditional result (X) was derived from value of type 'T'.
# Conditionals must have a boolean result." This engine used to apply
# Python-ish truthiness and run or skip instead - so a task real Ansible
# refuses to decide at all silently took a branch here.
#
# Differentialed against ansible-core 2.19.4 over every shape below,
# including the ANSIBLE_ALLOW_BROKEN_CONDITIONALS escape hatch, which
# real Ansible honours and this project's own benchmark harness has set
# on the real-Ansible side since round 20.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

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

    status.exit_code.should eq(2)
    output.should contain("Conditional result (True) was derived from value of type 'str'")
    output.should contain("Conditionals must have a boolean result")
    output.should_not contain("TASK-RAN")
  end

  # The case that silently diverged: this engine read "false" as false
  # and skipped, where real Ansible refuses the conditional outright.
  it "fails for the string 'false' rather than quietly skipping" do
    status, output = run_playbook(playbook_for("s_false"))

    status.exit_code.should eq(2)
    output.should contain("Conditional result (True) was derived from value of type 'str'")
  end

  it "reports (False) for an empty string" do
    status, output = run_playbook(playbook_for("empty_str"))

    status.exit_code.should eq(2)
    output.should contain("Conditional result (False) was derived from value of type 'str'")
  end

  it "fails for an int-valued condition" do
    status, output = run_playbook(playbook_for("n_one"))

    status.exit_code.should eq(2)
    output.should contain("Conditional result (True) was derived from value of type 'int'")
  end

  it "fails for a list-valued condition" do
    status, output = run_playbook(playbook_for("my_list"))

    status.exit_code.should eq(2)
    output.should contain("Conditional result (True) was derived from value of type 'list'")
  end

  # adfinis-sygroup.network's `when: network_interfaces is defined and
  # network_interfaces` with the var defaulting to `[]` (round 84003):
  # the `and` chain's deciding operand is the list itself, so the whole
  # conditional's result is list-typed (Python's `and` returns the
  # operand, not a bool) - real Ansible fails the task with the
  # "Task failed: " prefix this error class carries, not the generic
  # "Error while evaluating conditional: " wrapper an undefined
  # reference gets.
  it "fails an `X is defined and X` chain ending in a list as 'Task failed: ...' (round 84003)" do
    status, output = run_playbook(playbook_for("my_list is defined and my_list"))

    status.exit_code.should eq(2)
    output.should contain("Task failed: Conditional result (True) was derived from value of type 'list'")
    output.should contain("Conditionals must have a boolean result")
    output.should_not contain("TASK-RAN")
  end

  it "accepts a genuine boolean" do
    status, output = run_playbook(playbook_for("real_bool"))

    status.exit_code.should eq(0)
    output.should contain("TASK-RAN")
  end

  # Real boolean operators produce real booleans, so these keep working
  # untouched - the rule is about the RESULT's type, not the syntax.
  it "accepts comparisons, membership and defined-ness tests" do
    ["s_text == 'hello'", "s_text != 'x'", "1 in my_list", "s_text is defined",
     "s_text | length > 0", "my_list | length == 2"].each do |condition|
      status, output = run_playbook(playbook_for(condition))
      status.exit_code.should eq(0)
      output.should contain("TASK-RAN")
    end

    # `not <string>` is a real boolean too - it just happens to be
    # false here, so the task is skipped rather than failed (verified
    # against real Ansible, which skips it identically).
    status, output = run_playbook(playbook_for("not s_text"))
    status.exit_code.should eq(0)
    output.should_not contain("TASK-RAN")
  end

  it "relaxes to truthiness under ANSIBLE_ALLOW_BROKEN_CONDITIONALS" do
    env = {"ANSIBLE_ALLOW_BROKEN_CONDITIONALS" => "true"}

    status, output = run_playbook(playbook_for("s_text"), env)
    status.exit_code.should eq(0)
    output.should contain("TASK-RAN")

    # ...including the falsy side: the task is skipped, not failed.
    status, output = run_playbook(playbook_for("s_false"), env)
    status.exit_code.should eq(0)
    output.should_not contain("TASK-RAN")
  end

  # Round 400022 (crazikpl.logging): a LIST-form when: is real Ansible's
  # own sequence of INDEPENDENT conditionals, each type-checked
  # separately - `when: [(str or b2), b]` fails there ("Conditional
  # result (True) was derived from value of type 'str'") even though the
  # equivalent single-string `when: (str or b2) and b` PASSES (Python's
  # `and` returns the last operand, so only the whole expression's
  # result type is checked - verified live against 2.19.4 over both
  # shapes). Joining the list into one `and` string and strict-checking
  # only the JOINED result made the whole-file divergence: krikri ran
  # the role's tasks where real ansible-playbook failed outright.
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
    status.exit_code.should eq(2)
    output.should contain("Conditional result (True) was derived from value of type 'str'")
    output.should contain("Conditionals must have a boolean result")
    output.should_not contain("TASK-RAN")
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
    status.exit_code.should eq(0)
    output.should contain("TASK-RAN")
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
    status.exit_code.should eq(0)
    output.should_not contain("TASK-RAN")
    output.should_not contain("Error while evaluating conditional")
  end
end
