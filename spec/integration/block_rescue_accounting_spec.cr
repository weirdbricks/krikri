require "../spec_helper"

# A block:'s body failures move into the recap's "rescued" counter as
# soon as rescue: is ENTERED - not only when the rescue itself then
# succeeds. Live-verified against real ansible-core 2.19.12 on Rocky 9.6
# (round173): a failing block task plus a rescue: that ALSO fails recaps
# as `failed=1 rescued=1`, not `failed=2 rescued=0`. Only the rescue's
# own failure counts as a play failure.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("block-rescue-accounting", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "block: rescue accounting" do
  it "counts a failing rescue: as failed=1 rescued=1, not failed=2" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: the block
            block:
              - name: block one
                ansible.builtin.command: /bin/false
            rescue:
              - name: rescue one
                ansible.builtin.command: /bin/false
            always:
              - name: always one
                ansible.builtin.debug:
                  msg: "always ran"
      YAML

    status.exit_code.should eq(2)
    output.should contain("always ran")
    output.should contain("failed=1")
    output.should contain("rescued=1")
  end

  it "still recaps a SUCCEEDING rescue: as failed=0 rescued=1" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: the block
            block:
              - name: block one
                ansible.builtin.command: /bin/false
            rescue:
              - name: rescue one
                ansible.builtin.debug:
                  msg: "rescued ok"
      YAML

    status.success?.should be_true
    output.should contain("rescued ok")
    output.should contain("failed=0")
    output.should contain("rescued=1")
  end
end

# A block: whose own when: RAISES also exercises the rescued counter:
# rescue: inherits the same failing condition and fails, yet the
# block-body failure is still moved into "rescued". Live-verified
# against ansible-core 2.19.12 (round173): failed=2 rescued=1.
describe "block: rescue accounting with a raising when:" do
  # Same shape plus a rescue:. Live-verified (round173): rescue: also
  # inherits the failing condition and fails, and the block-body failure
  # is still moved into "rescued" => failed=2 rescued=1.
  it "runs rescue: and always: too, recapping failed=2 rescued=1" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated block
            when: totally_undefined_var
            block:
              - name: block one
                ansible.builtin.debug:
                  msg: "should not print"
            rescue:
              - name: rescue one
                ansible.builtin.debug:
                  msg: "should not print"
            always:
              - name: always one
                ansible.builtin.debug:
                  msg: "should not print"
      YAML

    status.exit_code.should eq(2)
    output.should_not contain("Unhandled exception")
    output.should_not contain("should not print")
    output.should contain("failed=2")
    output.should contain("rescued=1")
  end
end
