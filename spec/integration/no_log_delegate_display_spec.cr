require "../spec_helper"

# Regression specs for the dirless-infra findings (Bug 3): a
# delegate_to: + delegate_facts: task must (a) censor the loop item on
# no_log tasks - `(item=(censored due to no_log))`, never the raw item
# value - and (b) show the delegation target on the host line,
# `ok: [localhost -> node1]`, matching real ansible-playbook's own
# display. Previously the item printed verbatim and the line stayed
# `ok: [localhost]`, hiding both the security control and which host
# the action actually ran against.
#
# These drive the compiled binary (the display layer is puts-based),
# same harness style as ignore_errors_recap_stats_spec.cr.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("no-log-delegate-display", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def run_playbook_with_inventory(inventory : String, yaml : String)
  playbook = File.tempname("no-log-delegate-display", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "no_log censoring and delegate_to display" do
  it "censors the loop item on a no_log task" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fan out a secret
            no_log: true
            ansible.builtin.set_fact:
              ops_key: "secret123"
            delegate_to: localhost
            delegate_facts: true
            loop:
              - very-secret-item
              - another-secret-item
      YAML

    output.should contain("(item=(censored due to no_log))")
    output.should_not contain("very-secret-item")
    output.should_not contain("another-secret-item")
  end

  it "shows the delegation target on the host line" do
    inventory = File.tempname("no-log-delegate-inv", ".ini")
    File.write(inventory, "localhost ansible_connection=local\nnode1 ansible_connection=local\n")
    _status, output = run_playbook_with_inventory(inventory, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fan out a fact
            ansible.builtin.set_fact:
              ops_url: "https://admin.example.com"
            delegate_to: "{{ item }}"
            delegate_facts: true
            loop:
              - node1
      YAML

    output.should contain("ok: [localhost -> node1] => (item=node1)")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
  end

  it "does not add a self-delegation arrow for delegate_to the same host" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fan out a fact
            ansible.builtin.set_fact:
              ops_url: "https://admin.example.com"
            delegate_to: localhost
            delegate_facts: true
            loop:
              - first-item
      YAML

    output.should contain("ok: [localhost] => (item=first-item)")
    output.should_not contain("localhost -> localhost")
  end
end
