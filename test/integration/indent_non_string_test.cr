require "../minitest_helper"

# Regression spec for issue #115 (bodsch.dhcpd): `none | indent(...)` fails
# on real ansible-core 2.19.11 with "The filter plugin
# 'ansible.builtin.indent' failed: unsupported operand type(s) for +=:
# 'NoneType' and 'str'", naming the input's own Python type. krikri used to
# report "No filter named 'indent'." (None) or hardcode 'int'.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("indent-non-string", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def indent_play(expr : String) : String
  <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - debug: msg="{{ #{expr} }}"
    YAML
end

describe "indent filter on non-string input" do
  it "names NoneType for None" do
    status, output = run_playbook(indent_play("none | indent(2, first=False)"))

    status.exit_code.must_equal(2)
    output.must_include("The filter plugin 'ansible.builtin.indent' failed: unsupported operand type(s) for +=: 'NoneType' and 'str'")
    output.wont_include("No filter named")
  end

  it "names int for a number" do
    status, output = run_playbook(indent_play("5 | indent(2)"))

    status.exit_code.must_equal(2)
    output.must_include("The filter plugin 'ansible.builtin.indent' failed: unsupported operand type(s) for +=: 'int' and 'str'")
  end

  it "still indents a string" do
    status, output = run_playbook(indent_play("'a\\nb' | indent(2)"))

    status.exit_code.must_equal(0)
    output.must_include("a\\n  b")
  end
end
