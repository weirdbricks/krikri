require "../spec_helper"

# Rounds 83382 (aheimsbakk.restic_backup) / 83389 (ahnooie.rdiff-backup-
# script): a `delegate_to: "{{ var }}"` whose variable is never defined
# used to render as the literal string "undefined", become a Host literally
# named "undefined", and die as an UNHANDLED Crystal exception at plugin-
# upload SSH time ("ssh: Could not resolve hostname undefined") - aborting
# the whole run instead of failing just the task the way real Ansible does
# ("'restic_backup_destination_server' is undefined").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("delegate-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "undefined delegate_to: variable" do
  it "fails the task cleanly, naming the variable, instead of connecting to a host named 'undefined'" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: delegate to undefined var
            ansible.builtin.debug:
              msg: "SHOULD-NOT-PRINT"
            delegate_to: "{{ undefined_delegate_var }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_delegate_var' is undefined")
    output.should_not contain("SHOULD-NOT-PRINT")
    output.should_not contain("SENTINEL-SHOULD-NOT-RUN")
    # Never an unhandled exception / bogus hostname connection attempt.
    output.should_not contain("Unhandled exception")
    output.should_not contain("Could not resolve hostname")
    output.should contain("failed=1")
  end

  it "is also strict for a looped task, degrading to one clean failed task" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped delegate to undefined var
            ansible.builtin.debug:
              msg: "SHOULD-NOT-PRINT"
            delegate_to: "{{ undefined_delegate_var }}"
            loop:
              - a
              - b
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_delegate_var' is undefined")
    output.should_not contain("Unhandled exception")
    output.should contain("failed=1")
  end

  # Real Ansible evaluates when: BEFORE delegate_to:, so the common
  # `when: var is defined` guard skips cleanly without ever templating
  # the delegate target.
  it "skips cleanly when a when: var is defined guard is False" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: delegate guarded by is defined
            ansible.builtin.debug:
              msg: "SHOULD-NOT-PRINT"
            when: undefined_delegate_var is defined
            delegate_to: "{{ undefined_delegate_var }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-OK"
      YAML

    status.success?.should be_true
    output.should contain("skipping:")
    output.should contain("SENTINEL-OK")
    output.should_not contain("SHOULD-NOT-PRINT")
    output.should contain("failed=0")
  end

  it "still delegates to a defined templated target" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          delegate_target: localhost
        tasks:
          - name: delegate to defined var
            ansible.builtin.debug:
              msg: "DEFINED-DELEGATE-OK"
            delegate_to: "{{ delegate_target }}"
      YAML

    status.success?.should be_true
    output.should contain("DEFINED-DELEGATE-OK")
    output.should contain("failed=0")
  end
end
