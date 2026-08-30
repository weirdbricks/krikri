require "../spec_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("assert-strict-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# assert:'s own that: is strict-undefined too, and reports it with the
# SAME message as a when: does - not as an ordinary "Assertion failed".
# Live-verified against real ansible-core 2.19.12 on Rocky 9.6
# (round173, via buluma.mount).
describe "assert: strict-undefined that:" do
  it "reports a bare undefined var as a conditional error, not 'Assertion failed'" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare undefined in assert
            ansible.builtin.assert:
              that:
                - totally_undefined_var
      YAML

    status.exit_code.should eq(2)
    output.should contain("Error while evaluating conditional")
    output.should contain("totally_undefined_var")
    output.should_not contain("Assertion failed")
    output.should contain("failed=1")
  end

  it "stays lenient for a default()/is-defined chain inside that:" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: assert with default
            ansible.builtin.assert:
              that:
                - totally_undefined_var | default(true)
          - name: assert is not defined
            ansible.builtin.assert:
              that:
                - totally_undefined_var is not defined
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should contain("failed=0")
  end
end
