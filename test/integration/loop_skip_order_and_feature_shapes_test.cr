require "../minitest_helper"
require "file_utils"

# Feature-level shapes live-compared byte for byte with ansible-playbook 2.19.11
# (scripts/output_parity.sh): when:-skipped loop items print in iteration order
# with a trailing space, block-level ignore_errors reaches rescue tasks,
# ansible_failed_task/result exist inside rescue, skipped registers carry
# false_condition and failed_when adds failed_when_result.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_text(text : String) : String
  playbook = File.tempname("feature-shapes", ".yml")
  File.write(playbook, text)
  captured = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  captured.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "feature-level output shapes" do
  it "prints when:-skipped loop items in iteration order with Ansible's trailing space" do
    text = run_playbook_text(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: {msg: "{{ item }}"}
            loop: [a, b, c]
            when: item != 'b'
      YAML
    lines = text.lines.map(&.chomp).select { |line| line.starts_with?("ok:") || line.starts_with?("skipping:") }
    lines.must_equal(["ok: [localhost] => (item=a) => {", "skipping: [localhost] => (item=b) ", "ok: [localhost] => (item=c) => {"])
  end

  it "applies a block's ignore_errors to rescue tasks and binds ansible_failed_task/result" do
    text = run_playbook_text(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - block:
              - ansible.builtin.fail: {msg: boom}
            rescue:
              - ansible.builtin.debug:
                  msg: "{{ ansible_failed_task.name }}|{{ ansible_failed_result.msg }}"
          - block:
              - ansible.builtin.fail: {msg: first}
            rescue:
              - ansible.builtin.fail: {msg: second}
            ignore_errors: true
          - ansible.builtin.debug: {msg: after}
      YAML
    text.must_include(%(|boom"))
    text.must_include("...ignoring")
    text.must_include(%("msg": "after"))
  end

  it "adds false_condition to skipped registers and failed_when_result to failed_when results" do
    text = run_playbook_text(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: {msg: x}
            when: false
            register: sk
          - ansible.builtin.debug: {var: sk}
          - ansible.builtin.command: "echo bad"
            register: r
            failed_when: "'bad' in r.stdout"
            ignore_errors: true
      YAML
    text.must_include(%("false_condition": false))
    text.must_include(%("skipped": true))
    text.must_include("[ERROR]: Task failed: Action failed.")
    text.must_include(%("failed_when_result": true))
  end
end
