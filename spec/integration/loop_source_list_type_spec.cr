require "../spec_helper"

# A loop: source that IS defined but isn't a list is a hard type error in
# real Ansible, with its own distinct wording. Live-verified against
# ansible-core 2.19.12 on Rocky 9.6 (round174 differential matrix
# scenarios 11a and 11c) - this engine used to run the task once with
# `item` bound to the non-list value.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("loop-list-type", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop: source must resolve to a list" do
  # Scenario 11a - verbatim real-Ansible wording, backticks and all.
  it "rejects an explicit null source as NoneType" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          nullvar: null
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ nullvar }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.should contain("failed=1")
  end

  # Scenario 11c.
  it "rejects a scalar string source as str" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          scalarvar: "hello"
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ scalarvar }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("The `loop` value must resolve to a 'list', not 'str'.")
    output.should contain("failed=1")
  end

  # The legacy array-wrapped form (`with_items: ["{{ var }}"]`) keeps its
  # documented flatten-a-scalar-to-one-item leniency - that is a
  # different source shape, and loop_scalar_flatten_spec.cr pins it.
  it "keeps the array-wrapped form's scalar-flatten leniency" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          scalarvar: "hello"
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "got {{ item }}"
            with_items:
              - "{{ scalarvar }}"
      YAML

    status.success?.should be_true
    output.should contain("got hello")
    output.should_not contain("must resolve to a 'list'")
  end
end
