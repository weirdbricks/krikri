require "../minitest_helper"

# Regression spec for issue #1088: a looped task skipped by a when:-false
# records its per-item result BEFORE ansible post-validates no_log, and
# the default callback censors that result on the RAW no_log value. A
# templated no_log (or a quoted "false") that resolves false therefore
# still censors, which strips the item label and makes real print
# `skipping: [host] => (item=None)` - krikri used to print the item.
# Only a no_log that really resolves true keeps the `_ansible_no_log`
# marker and shows `(item=(censored due to no_log))`. Live-verified vs
# ansible-core 2.21.6.
#
# Drives the compiled binary (the display layer is puts-based), same
# harness style as no_log_include_loop_item_test.cr.
private SNL_ROOT = File.expand_path("../..", __DIR__)
private SNL_BIN  = File.join(SNL_ROOT, "bin", "krikri-playbook")
private SNL_INV  = File.join(SNL_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_skipped_no_log_playbook(yaml : String)
  playbook = File.tempname("skipped-no-log-loop-label", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(SNL_BIN, ["-i", SNL_INV, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "skipped loop item labels under a raw-truthy no_log" do
  it "prints item=None for a templated no_log that resolves false" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hide_passwords: false
        tasks:
          - name: templated-false secret loop
            ansible.builtin.shell: echo "{{ item }}"
            no_log: "{{ hide_passwords }}"
            with_items:
              - secret-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=None)")
    output.wont_include("secret-item")
    output.wont_include("censored due to no_log")
  end

  it "prints item=None for a quoted string no_log" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: quoted-false secret loop
            ansible.builtin.shell: echo "{{ item }}"
            no_log: "false"
            with_items:
              - secret-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=None)")
    output.wont_include("secret-item")
  end

  it "keeps the item and censored label for a literal no_log false" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: literal-false loop
            ansible.builtin.shell: echo "{{ item }}"
            no_log: false
            with_items:
              - plain-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=plain-item)")
    output.wont_include("item=None")
  end

  it "keeps the censored label for a no_log that resolves true" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hide_passwords: true
        tasks:
          - name: templated-true secret loop
            ansible.builtin.shell: echo "{{ item }}"
            no_log: "{{ hide_passwords }}"
            with_items:
              - secret-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=(censored due to no_log))")
    output.wont_include("secret-item")
  end

  it "prints item=None for a block-inherited templated no_log that resolves false" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hide_passwords: false
        tasks:
          - name: hidden block
            block:
              - name: templated-false secret loop
                ansible.builtin.shell: echo "{{ item }}"
                with_items:
                  - secret-item
                when: false
            no_log: "{{ hide_passwords }}"
      YAML

    output.must_include("skipping: [localhost] => (item=None)")
    output.wont_include("secret-item")
  end

  it "prints item=None for a skipped looped task inside a when-false block" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hide_passwords: false
        tasks:
          - name: skipped block
            block:
              - name: templated-false secret loop
                ansible.builtin.shell: echo "{{ item }}"
                no_log: "{{ hide_passwords }}"
                with_items:
                  - secret-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=None)")
    output.wont_include("secret-item")
  end

  it "prints item=None on a skipped looped handler" do
    _status, output = run_skipped_no_log_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          hide_passwords: false
        tasks:
          - name: trigger the handler
            ansible.builtin.command: echo trigger
            changed_when: true
            notify: skipped secret handler
        handlers:
          - name: skipped secret handler
            ansible.builtin.shell: echo "{{ item }}"
            no_log: "{{ hide_passwords }}"
            with_items:
              - secret-item
            when: false
      YAML

    output.must_include("skipping: [localhost] => (item=None)")
    output.wont_include("secret-item")
  end
end
