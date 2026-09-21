require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# Regression for the shape 21077616's fix didn't cover: the same
# map('extract', hostvars, ...) raise, but reached through a
# play-level `vars:` folded scalar (`>-`) whose lazy template value is
# only rendered when a `debug: var:` displays it. The filter-level
# raise (locked in by spec/unit/filter_engine_spec.cr and
# spec/unit/crinja_renderer_spec.cr) fired correctly there, but the
# debug action plugin stopped at the raw VariableLookup#resolve and
# printed the unrendered `{{ ... }}` string as the var's value - the
# templating error never surfaced, the task succeeded, and a
# bad-inventory playbook ran on (real ansible-playbook aborts the play,
# exit 2). Real debug templates the looked-up value through the
# Templar, so the error must fail the task; a lazy var that renders
# cleanly must still display its rendered value.
describe "debug: var renders lazy template values (and surfaces their errors)" do
  it "fails with the HostVarsVars message for the chained extract shape" do
    inventory = File.tempname("extract-inventory", ".ini")
    File.write(inventory, <<-INI)
      [backend_nodes]
      node1 ansible_connection=local node_ip=10.0.0.1
      node2 ansible_connection=local node_ip=10.0.0.2
      node3 ansible_connection=local node_ip=10.0.0.3
      INI

    playbook = File.tempname("extract-lazy-var", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: backend_nodes
        gather_facts: false
        vars:
          expected_ips: >-
            {{ groups['backend_nodes'] | default([])
               | map('extract', hostvars, 'ansible_host')
               | list | sort }}
        tasks:
          - name: show expected ips
            ansible.builtin.debug:
              var: expected_ips
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should contain("object of type 'HostVarsVars' has no attribute 'ansible_host'")
    output.to_s.should_not contain("groups['backend_nodes']")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still renders a lazy var that extracts an existing attribute" do
    inventory = File.tempname("extract-inventory", ".ini")
    File.write(inventory, <<-INI)
      [backend_nodes]
      node1 ansible_connection=local node_ip=10.0.0.1
      node2 ansible_connection=local node_ip=10.0.0.2
      INI

    playbook = File.tempname("extract-lazy-var-ok", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: backend_nodes
        gather_facts: false
        vars:
          expected_ips: >-
            {{ groups['backend_nodes'] | default([])
               | map('extract', hostvars, 'node_ip')
               | list | sort }}
        tasks:
          - name: show expected ips
            ansible.builtin.debug:
              var: expected_ips
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("10.0.0.1")
    output.to_s.should contain("10.0.0.2")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
