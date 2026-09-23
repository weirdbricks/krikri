require "../spec_helper"

# The 0.9.1267 open gap, live-verified against real ansible-core 2.19.11:
# a set_fact: whose single-pass render OUTPUT contains brace text (here
# via a quoted literal - the stored value is the literal string
# `{{ inner_undefined_name }}`), or a registered command: stdout holding
# the same, is RESOLVED. Real Ansible tags facts/module results resolved
# and never re-scans their text: a later msg: that references the value
# prints the brace text verbatim, rc=0. krikri treated the stored text as
# ANOTHER template level, looked the inner name up, and died with
# "'inner_undefined_name' is undefined" as an UNHANDLED exception that
# killed the whole controller process - not even a task failure.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("resolved-brace-text", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "resolved set_fact/register values containing brace text" do
  it "passes a set_fact value holding literal {{ }} through verbatim" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: store a resolved value that looks like a template
            ansible.builtin.set_fact:
              x: "{{ '{{ inner_undefined_name }}' }}"
          - name: reference it
            ansible.builtin.debug:
              msg: "value=[{{ x }}]"
      YAML

    status.success?.should be_true
    output.should contain("value=[{{ inner_undefined_name }}]")
    output.should_not contain("inner_undefined_name' is undefined")
  end

  # The brace text must enter the registered stdout through a QUOTED
  # LITERAL (the round-191 shape), not raw braces in the cmd: itself -
  # arg finalization renders those, and real Ansible fails that shape
  # identically.
  it "passes a registered command stdout holding brace text through verbatim" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: produce brace text on stdout
            ansible.builtin.command:
              cmd: '{{ ''echo "{{ inner_undefined_name }}"'' }}'
            register: probe
          - name: reference the registered stdout
            ansible.builtin.debug:
              msg: "stdout=[{{ probe.stdout }}]"
      YAML

    status.success?.should be_true
    output.should contain("stdout=[{{ inner_undefined_name }}]")
    output.should_not contain("inner_undefined_name' is undefined")
  end

  it "still re-templates a YAML-defined vars: default that is a template" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mount:
            mode: "{{ dir_mode }}"
          dir_mode: "2750"
        tasks:
          - name: reference the nested template default
            ansible.builtin.debug:
              msg: "mode={{ mount.mode }}"
      YAML

    status.success?.should be_true
    output.should contain("mode=2750")
  end
end
