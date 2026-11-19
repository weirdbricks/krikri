require "../minitest_helper"

# Regression spec for issue #1572 (ucr.mailman3): ansible post-validates
# no_log per loop ITEM - it copies the task and re-templates the keyword
# against that item's own vars - so a role's `no_log: "{{ item.vtype ==
# 'password' }}"` censors only the secret iterations and prints the other
# items normally. krikri resolved the expression once against a context
# built before `item` was bound, so no item was ever censored and the
# password dicts (and their module payloads) printed in full.
# Live-verified vs ansible-core 2.21.6.
#
# Drives the compiled binary (the display layer is puts-based), same
# harness style as skipped_no_log_loop_item_label_test.cr.
private LPIN_ROOT = File.expand_path("../..", __DIR__)
private LPIN_BIN  = File.join(LPIN_ROOT, "bin", "krikri-playbook")
private LPIN_INV  = File.join(LPIN_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_per_item_no_log_playbook(yaml : String)
  playbook = File.tempname("per-item-no-log", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(LPIN_BIN, ["-i", LPIN_INV, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "no_log templated per loop item" do
  it "censors only the items whose no_log resolves true" do
    _status, output = run_per_item_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: per-item no_log
            vars:
              this_no_log: "{{ true if item.vtype == 'password' else false }}"
            loop:
              - {name: 'plain-question', vtype: 'string', value: 'visible-value'}
              - {name: 'secret-question', vtype: 'password', value: 'change_db_pass'}
            no_log: "{{ this_no_log }}"
            ansible.builtin.debug:
              var: item.name
      YAML

    output.must_include("ok: [localhost] => (item={'name': 'plain-question', 'vtype': 'string', 'value': 'visible-value'})")
    output.must_include("ok: [localhost] => (item=(censored due to no_log))")
    output.wont_include("secret-question")
    output.wont_include("change_db_pass")
  end

  it "censors only the failing items whose no_log resolves true" do
    _status, output = run_per_item_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: per-item no_log failure
            vars:
              this_no_log: "{{ true if item.vtype == 'password' else false }}"
            loop:
              - {name: 'plain-question', vtype: 'string'}
              - {name: 'secret-question', vtype: 'password'}
            no_log: "{{ this_no_log }}"
            ansible.builtin.fail:
              msg: "boom {{ item.name }}"
            ignore_errors: true
      YAML

    output.must_include("failed: [localhost] (item={'name': 'plain-question', 'vtype': 'string'})")
    output.must_include("failed: [localhost] (item=(censored due to no_log))")
    output.wont_include("secret-question")
  end

  it "leaves a loop with a literal no_log: true fully censored" do
    _status, output = run_per_item_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: literal no_log loop
            no_log: true
            loop:
              - very-secret-item
            ansible.builtin.debug:
              var: item
      YAML

    output.must_include("ok: [localhost] => (item=(censored due to no_log))")
    output.wont_include("very-secret-item")
  end
end
