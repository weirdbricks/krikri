require "../minitest_helper"

# Issue #111: ansible-core 2.19.11 labels a non-boolean conditional error
# with " at '<file>:<line>:<col>'" for compound expressions too. An and/or
# chain points at the defining position of the variable operand that decided
# it; a filter result is a fresh value, labelled with the when: token.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("strict-conditionals-origin", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "strict conditional origin for compound expressions" do
  it "labels an and-chain with the deciding variable's defining position" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        nvm_dir: ""
        nvm_profile: ""
      tasks:
        - fail:
          when: nvm_dir and not nvm_profile
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'str' at '#{playbook}:5:14'. Conditionals must have a boolean result.")
  end

  it "labels an and-chain with quoted comparison operands after the deciding variable" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        nvm_dir: ""
        nvm_profile: ".bashrc"
        nvm_install: "wget"
      tasks:
        - fail:
          when: nvm_dir and nvm_profile == '.bashrc' and nvm_install != 'git'
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'str' at '#{playbook}:5:14'. Conditionals must have a boolean result.")
  end

  it "labels a filter result with the when: token position" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        lst: []
      tasks:
        - fail:
          when: lst | d([], true)
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'list' at '#{playbook}:8:13'. Conditionals must have a boolean result.")
  end

  # Issue #342: a YAML null has no origin tag in real 2.19 - its strict
  # check reports `at '<unknown>'`, no file position, while the chain's
  # own tracing Origin: block keeps the when: token position.
  it "labels a bare null variable's error with '<unknown>'" do
    status, output, _playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        nullvar:
      tasks:
        - fail:
          when: nullvar
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'NoneType' at '<unknown>'. Conditionals must have a boolean result.")
    output.must_include("\"msg\": \"Task failed: Conditional result (False) was derived from value of type 'NoneType' at '<unknown>'. Conditionals must have a boolean result.\"")
  end

  it "labels a null variable in a compound clause with '<unknown>'" do
    status, output, _playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        users_group:
      tasks:
        - fail:
          when: users_group is defined and users_group
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Conditional result (False) was derived from value of type 'NoneType' at '<unknown>'. Conditionals must have a boolean result.")
  end
end
