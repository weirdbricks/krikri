require "file_utils"
require "../spec_helper"

# Round 188: a gated `import_tasks:` whose child file's last task
# references a `register:` from a prior inner task that the gate
# will skip - the whole file is skipped, the child's `when:` is
# never evaluated, and a strict-undefined reference to a missing
# registered var does NOT raise. Pre-fix this raised
# "'item_stat.stat.exists' is undefined" at the child's when-eval,
# aborting the play even though real Ansible would have skipped the
# whole file at the parent `when: false` decision.
#
# Reproducer: weareinteractive.openssl/tasks/create_dir.yml, used by
# weareinteractive.vsftpd (Ubuntu 22.04) - the exact play that
# surfaced the bug. The structure is one parent task with
# `import_tasks: ... when: <gate>` and two child tasks, the first
# `stat:`-ing and registering, the second `file:`-ing with
# `when: not <reg>.stat.exists`. With the gate false, both inner
# tasks are skipped, but the second one's `when:` references the
# (never-set) registered var.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String, inner : String) : {Process::Status, String}
  dir = File.tempname("import-tasks-parent-when-188")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inner.yml"), inner)
  playbook_path = File.join(dir, "pb.yml")
  File.write(playbook_path, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook_path], output: captured, error: captured)
  {status, captured.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# Minimal child file shape, matching weareinteractive.openssl/tasks/create_dir.yml
# (the file that surfaced the round 188 bug). One task that sets a
# `register:`-d var via `stat:`, then one task whose `when:` references
# that var. When the parent's `when:` is false, both child tasks skip.
INNER = <<-YAML
  - name: Checking dir exists
    ansible.builtin.stat:
      path: "{{ item }}"
    register: item_stat
  - name: Creating directory
    ansible.builtin.file:
      path: "{{ item }}"
      state: directory
      mode: "{{ mode }}"
    when: not item_stat.stat.exists
  YAML

describe "import_tasks: parent when: short-circuits the child when:" do
  # The exact shape from the role (with one gating + two
  # non-gating invocations, so the recap also has ok>0 to prove
  # the non-gated branch actually ran).
  it "skips the gated import_tasks entirely, without raising on the child's register-ref" do
    status, output = run_playbook(<<-YAML, INNER)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          openssl_generate_csr: false
          openssl_certs_path: /tmp
          openssl_keys_path: /tmp
          openssl_csrs_path: /tmp
        tasks:
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_certs_path }}"
              mode: "0755"
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_keys_path }}"
              mode: "0700"
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_csrs_path }}"
              mode: "0750"
            when: openssl_generate_csr | bool
      YAML

    # Pre-fix this raised "'item_stat.stat.exists' is undefined"
    # on the 3rd (gated) import, and exit code was 2.
    status.exit_code.should eq(0)
    output.should contain("PLAY RECAP")
    output.should_not contain("Error while evaluating conditional")
    output.should_not contain("is undefined")
  end

  # Edge case: same shape, but with the gate TRUE. The whole
  # import runs, the first child task runs and sets the registered
  # var, the second child's `when:` evaluates against the now-set
  # var. Verifies the fix doesn't break the unskipped case (which
  # was already working pre-fix, but worth pinning down).
  it "runs the gated import end-to-end when the gate is true" do
    status, output = run_playbook(<<-YAML, INNER)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          openssl_generate_csr: true
          openssl_certs_path: /tmp
          openssl_keys_path: /tmp
          openssl_csrs_path: /tmp
        tasks:
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_certs_path }}"
              mode: "0755"
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_keys_path }}"
              mode: "0700"
          - import_tasks: inner.yml
            vars:
              item: "{{ openssl_csrs_path }}"
              mode: "0750"
            when: openssl_generate_csr | bool
      YAML

    status.exit_code.should eq(0)
    output.should_not contain("Error while evaluating conditional")
    output.should contain("PLAY RECAP")
  end
end
