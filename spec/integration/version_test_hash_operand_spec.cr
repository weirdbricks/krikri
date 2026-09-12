require "../spec_helper"

# `x is version('2.7', '<')` with the bare `ansible_version` magic-var
# DICT as the left operand - a role-side bug, but one real Ansible turns
# into a hard task failure, found via timorunge.pmm_client's own
# `tasks/preinst.yml`:
#
#   update_cache: "{{ omit if ((ansible_pkg_mgr == 'dnf') and
#     (ansible_version is version('2.7', '<'))) else 'yes' }}"
#
# Real ansible-core 2.19 (verified live, `ansible_connection=local`) tries
# to version-compare the stringified dict and fails the task with
# "Version comparison failed: '<' not supported between instances of
# 'str' and 'int'" - "Finalization of task args for
# 'ansible.builtin.package' failed" - and the play halts (recap
# ok=3 failed=1 skipped=0). This engine's evaluate_value happily
# stringified the whole compact-JSON dump, compare_versions' digit scan
# compared *something*, the ternary picked a branch, and the play
# continued into tasks real Ansible never reached (ok=5 failed=1
# skipped=1) - genuinely different tasks ran.
#
# The second example guards the correct, dotted-field usage
# (`ansible_version.string is version(...)`): the parent dict merely
# being IN SCOPE must not trip the Hash guard.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("version-hash-operand", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "version test with a Hash left operand" do
  it "fails the task instead of silently version-comparing the dict" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_pkg_mgr: dnf
          ansible_version:
            full: "2.19.0"
            major: 2
            minor: 19
            revision: 0
            string: "2.19.0"
        tasks:
          - name: Compute update_cache like timorunge.pmm_client
            ansible.builtin.debug:
              msg: "{{ omit if ((ansible_pkg_mgr == 'dnf') and (ansible_version is version('2.7', '<'))) else 'yes' }}"
          - name: should never run
            ansible.builtin.debug: {msg: "SHOULD-NOT-PRINT"}
      YAML

    status.success?.should be_false
    output.should contain("failed=1")
    output.should_not contain("SHOULD-NOT-PRINT")
  end

  it "still compares the dotted ansible_version.string field normally" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_pkg_mgr: dnf
          ansible_version:
            full: "2.19.0"
            major: 2
            minor: 19
            revision: 0
            string: "2.19.0"
        tasks:
          - name: dotted-field version gate
            ansible.builtin.debug: {msg: "DOTTED-RAN"}
            when: ansible_version.string is version('2.7', '>=')
          - name: dotted-field ternary like the role, but correct
            ansible.builtin.debug:
              msg: "{{ omit if ((ansible_pkg_mgr == 'dnf') and (ansible_version.string is version('2.7', '>='))) else 'yes' }}"
      YAML

    status.success?.should be_true
    output.should contain("DOTTED-RAN")
    output.should contain("failed=0")
  end
end
