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

  # Round 813350 (RedHatOfficial.rhel9_hipaa): the "Correct file
  # permissions with RPM" task loops
  # `with_items: "{{ list_of_packages.results | map(attribute='stdout_
  # lines') | list | unique }}"` - the map produces [[pkg], [pkg], ...]
  # and real ansible-playbook 2.19.11 flattens that one level before
  # iterating, so `item` reaches `rpm --restore '{{ item }}'` as a bare
  # scalar package name. krikri used to keep each item a one-element
  # nested list here (the whole-source filter-chain path in
  # resolve_loop_template).
  it "with_items: over a filter chain producing nested lists flattens one level" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          list_of_packages:
            results:
              - stdout_lines: ["pkgA"]
              - stdout_lines: ["pkgB"]
        tasks:
          - name: filter chain flatten
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_items: "{{ list_of_packages.results | map(attribute='stdout_lines') | list | unique }}"
      YAML

    status.success?.should be_true
    output.should contain("item=pkgA")
    output.should contain("item=pkgB")
    output.should_not contain("['pkgA']")
    output.should_not contain("['pkgB']")
  end

  # Same flatten for the direct whole-variable template form
  # (`with_items: "{{ nested }}"`, not a filter chain) - real Ansible
  # applies its one-level flatten regardless of how the source
  # resolved to a list of lists.
  it "with_items: over a direct template resolving to nested lists flattens one level" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          nested:
            - ["pkgA"]
            - ["pkgB"]
        tasks:
          - name: direct template flatten
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_items: "{{ nested }}"
      YAML

    status.success?.should be_true
    output.should contain("item=pkgA")
    output.should contain("item=pkgB")
    output.should_not contain("['pkgA']")
    output.should_not contain("['pkgB']")
  end

  # loop: has no such legacy flatten - the nested lists must survive
  # as items (same rule the array-literal example above already pins
  # for the multi-source form, here for a single whole-source template).
  it "loop: over the same nested-list template does NOT flatten" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          nested:
            - ["pkgA"]
            - ["pkgB"]
        tasks:
          - name: no flatten for loop
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: "{{ nested }}"
      YAML

    status.success?.should be_true
    output.should contain("['pkgA']")
    output.should contain("['pkgB']")
  end
end
