require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks, since -v/-vv/-vvv
# CLI parsing and the ansible_verbosity magic var are entirely a
# krikri-playbook.cr/executor.cr concern, not reachable from a unit
# spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Found via a live 100-role confirm round: marcinpraczko.goss-install's
# own `when: ansible_verbosity is defined` style check raised
# "'ansible_verbosity' is undefined" outright, since this magic var
# didn't exist anywhere in this engine before (real Ansible always
# defines it, defaulting to 0 with no -v at all). Fixing the magic var
# also required fixing debug:'s own pre-existing (separately dead)
# verbosity: gate, which always compared against a hardcoded 0.
describe "-v/-vv/-vvv and ansible_verbosity" do
  it "defaults ansible_verbosity to 0 with no -v flag" do
    playbook = File.tempname("verbosity-default", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "verbosity={{ ansible_verbosity }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("verbosity=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "stacks -vv/-vvv into the right numeric level, and repeated -v -v -v accumulates the same way" do
    playbook = File.tempname("verbosity-stacked", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "verbosity={{ ansible_verbosity }}"
      YAML

    {
      {["-vv"], "verbosity=2"},
      {["-vvv"], "verbosity=3"},
      {["-v", "-v", "-v"], "verbosity=3"},
    }.each do |(flags, expected)|
      output = IO::Memory.new
      status = Process.run(BINARY, flags + ["-i", INVENTORY, playbook], output: output, error: output)
      status.success?.should be_true
      output.to_s.should contain(expected)
    end
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "does not break positional playbook-file parsing with a bare -v" do
    playbook = File.tempname("verbosity-bare-v", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "verbosity={{ ansible_verbosity }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-v", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("verbosity=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "gates debug: verbosity: against the real current level, not a hardcoded 0" do
    playbook = File.tempname("verbosity-gate", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated low
            ansible.builtin.debug:
              msg: LOW_SHOULD_SHOW
              verbosity: 1
          - name: gated high
            ansible.builtin.debug:
              msg: HIGH_SHOULD_NOT_SHOW
              verbosity: 3
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-v", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("LOW_SHOULD_SHOW")
    output.to_s.should_not contain("HIGH_SHOULD_NOT_SHOW")
    output.to_s.should match(/ok=1\b/)
    output.to_s.should match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
