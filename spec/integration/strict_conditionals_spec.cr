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
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
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
end
