require "../minitest_helper"

# Rounds 83382 (aheimsbakk.restic_backup) / 83389 (ahnooie.rdiff-backup-
# script): a `delegate_to: "{{ var }}"` whose variable is never defined
# used to render as the literal string "undefined", become a Host literally
# named "undefined", and die as an UNHANDLED Crystal exception at plugin-
# upload SSH time ("ssh: Could not resolve hostname undefined") - aborting
# the whole run instead of failing just the task the way Ansible does
# ("'restic_backup_destination_server' is undefined").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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

    status.exit_code.must_equal(2)
    output.must_include("'undefined_delegate_var' is undefined")
    # The task's own msg literal also appears inside the [ERROR] block's
    # source excerpt now, so absence is checked via the executed-output
    # marker instead: the debug module never ran.
    output.wont_include("ok: [localhost]")
    output.must_include("ok=0")
    output.wont_include("SENTINEL-SHOULD-NOT-RUN")
    # Never an unhandled exception / bogus hostname connection attempt.
    output.wont_include("Unhandled exception")
    output.wont_include("Could not resolve hostname")
    output.must_include("failed=1")
  end

  # Issue #633 (stackhpc.os-ironic-state): a delegate_to: that renders to an
  # empty string is a task failure in ansible ("Empty hostname produced from
  # delegate_to"), not an ssh attempt to a host with no name.
  it "fails the task when delegate_to: renders to an empty hostname" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          empty_delegate_target: ""
        tasks:
          - name: delegate to empty var
            ansible.builtin.debug:
              msg: "SHOULD-NOT-PRINT"
            delegate_to: "{{ empty_delegate_target }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    status.exit_code.must_equal(2)
    output.must_include(%(Empty hostname produced from delegate_to: "{{ empty_delegate_target }}"))
    output.must_include(%(fatal: [localhost -> {{ empty_delegate_target }}]: FAILED!))
    output.wont_include("SHOULD-NOT-PRINT")
    output.wont_include("SENTINEL-SHOULD-NOT-RUN")
    output.wont_include("Could not resolve hostname")
    output.must_include("failed=1")
    output.must_include("unreachable=0")
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

    status.exit_code.must_equal(2)
    output.must_include("'undefined_delegate_var' is undefined")
    output.wont_include("Unhandled exception")
    output.must_include("failed=1")
  end

  # live-verified vs 2.19.11: delegate_to: templates BEFORE when:, so a
  # failing delegate template (undefined variable) fails the task even
  # behind a False when: guard - issue #661,
  # wittdennis.kubernetes_node_uncordon's "Wait for cilium" (when False
  # by default, delegate group undefined; real prints the fatal
  # [ERROR] block and aborts the play, krikri used to skip and run on).
  it "fails the task even when a when: guard is False, because ansible templates delegate_to: first" do
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

    status.exit_code.must_equal(2)
    output.must_include("'undefined_delegate_var' is undefined")
    output.must_include("fatal: [localhost -> {{ undefined_delegate_var }}]: FAILED!")
    output.wont_include("SENTINEL-OK")
    output.must_include("failed=1")
    output.must_include("skipped=0")
  end

  # The same delegate_to:-before-when: ordering for the dict-missing-key
  # shape: ansible words it "object of type 'dict' has no attribute
  # 'missing_key'" (live-verified vs 2.19.11, issue #661).
  it "fails the task for a dict-missing-key delegate even when when: is False" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          some_dict:
            existing: "x"
        tasks:
          - name: delegate to missing dict key
            ansible.builtin.debug:
              msg: "SHOULD-NOT-PRINT"
            when: false
            delegate_to: "{{ some_dict.missing_key }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-OK"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("object of type 'dict' has no attribute 'missing_key'")
    output.wont_include("SENTINEL-OK")
    output.must_include("failed=1")
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

    status.success?.must_equal(true)
    output.must_include("DEFINED-DELEGATE-OK")
    output.must_include("failed=0")
  end
end
