require "../spec_helper"

# Real Ansible's with_items: (unlike loop:) implicitly applies
# flatten(levels=1) across its rendered elements - found via
# nicolai86.prepare-release's own `with_items: ["{{ default_directories
# }}", "{{ directories }}"]` (two nested-list sources in one with_items:),
# which krikri used to bind the whole default_directories array as a
# single `item` instead of iterating its elements. Live-verified against
# ansible-core 2.19.12: `with_items: ["{{ list_a }}", "{{ list_b }}"]`
# iterates every INNER element across both lists, while the equivalent
# `loop:` form does NOT flatten (loop: has no such legacy behavior).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("with-items-flatten", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_items: flattens nested list sources one level, unlike loop:" do
  it "with_items: over two list-valued templates iterates each inner element" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          list_a: ["one", "two"]
          list_b: ["three"]
        tasks:
          - name: flatten test
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_items:
              - "{{ list_a }}"
              - "{{ list_b }}"
      YAML

    status.success?.should be_true
    output.should contain("item=one")
    output.should contain("item=two")
    output.should contain("item=three")
    output.should_not contain("['one', 'two']")
  end

  it "loop: over the same two list-valued templates does NOT flatten" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          list_a: ["one", "two"]
          list_b: ["three"]
        tasks:
          - name: no flatten
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop:
              - "{{ list_a }}"
              - "{{ list_b }}"
      YAML

    status.success?.should be_true
    output.should contain("['one', 'two']")
    output.should contain("['three']")
  end
end
