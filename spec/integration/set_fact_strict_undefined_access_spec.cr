require "../spec_helper"

# A set_fact: value whose expression ACCESSES a genuinely undefined
# variable - `undefined_var.split(':') | map(...) | list` - must fail the
# task at arg-finalization time, like real Ansible does for every module's
# args ("Finalization of task args for 'ansible.builtin.set_fact' failed:
# Error while resolving value for '_host_pattern_variants':
# 'conga_host_facts_pattern' is undefined", captured live in the round
# against wcm_io_devops.conga_host_facts' very first task).
#
# The strict-undefined machinery previously only covered BARE `{{ var }}`
# references and `var | filter` chains whose source is a bare reference -
# the moment the source itself carried parens (a method call), the
# expression silently rendered to `[]` and the task succeeded where real
# Ansible fatally fails.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("set-fact-strict-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "set_fact: strict-undefined arg finalization" do
  # THE core bug - wcm_io_devops.conga_host_facts' exact first task.
  it "fails a method-call chain on an undefined root, naming the root variable" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: "Set host_pattern facts."
            ansible.builtin.set_fact:
              _host_pattern_variants: "{{ conga_host_facts_pattern.split(':')
                                      | map('regex_replace', '.*conga_variants_', '')
                                      | list }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'conga_host_facts_pattern' is undefined")
    output.should_not contain("SENTINEL-SHOULD-NOT-RUN")
    output.should contain("failed=1")
  end

  # Same strictness for bracket access and a direct call on an undefined
  # root - real Ansible's StrictUndefined raises on all three access
  # shapes identically.
  it "fails bracket access on an undefined root" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bracket access
            ansible.builtin.set_fact:
              v: "{{ undefined_var['key'] | list }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("undefined_var")
    output.should contain("is undefined")
  end

  it "fails a direct call on an undefined root" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: direct call
            ansible.builtin.set_fact:
              v: "{{ undefined_var('arg') }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
  end

  # The lenient escape hatches must all keep working.
  it "stays lenient for a default() filter chain on a bare undefined root" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: tolerant chain
            ansible.builtin.set_fact:
              v: "{{ undefined_var | default([]) | list }}"
      YAML

    status.success?.should be_true
    output.should contain("failed=0")
  end

  it "stays lenient for an is defined test on an undefined root" do
    status, _output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: defined test
            ansible.builtin.set_fact:
              v: "{{ undefined_var is defined }}"
      YAML

    status.success?.should be_true
  end

  it "stays lenient for a Jinja global function root (lookup)" do
    status, _output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: global function
            ansible.builtin.set_fact:
              v: "{{ lookup('vars', 'definitely_not_set_anywhere', default='fallback') }}"
      YAML

    status.success?.should be_true
  end

  it "stays lenient for a method call on a DEFINED root" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          defined_var: "a:b:c"
        tasks:
          - name: defined root
            ansible.builtin.set_fact:
              v: "{{ defined_var.split(':') | list }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "{{ v | join('-') }}"
      YAML

    status.success?.should be_true
    output.should contain("a-b-c")
  end
end
