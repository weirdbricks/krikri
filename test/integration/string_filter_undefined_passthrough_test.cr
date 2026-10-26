require "../minitest_helper"

# Runs the compiled binary against real playbooks, since the difference
# only shows up in the rendered per-item output.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Issue #621 (robertdebock.postfix): a loop whose items are a ternary that
# discards `undefined | dirname` in its unselected branch, with a `when:`
# that is false. Ansible renders every item to '' and prints one
# `skipping: (item=)` line per item plus the task summary. Krikri's string
# filters raised on the undefined input before the ternary could discard
# it, so the strict item render failed and the whole loop collapsed to a
# single summary line.
describe "a string filter applied to an undefined value" do
  it "passes the undefined value through an unselected ternary branch" do
    playbook = File.tempname("passthrough-ternary", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: loop over discarded dirname
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ (undefined_v is defined) | ternary(undefined_v | dirname, '') }}"
              - "{{ (undefined_v is defined) | ternary(undefined_v | dirname, '') }}"
            when: undefined_flag is defined
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.scan("skipping: [localhost] => (item=) ").size.must_equal(2)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still fails when the undefined value is rendered directly" do
    playbook = File.tempname("passthrough-direct", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: render undefined through dirname
            ansible.builtin.debug:
              msg: "{{ undefined_v | dirname }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.includes?("'undefined_v' is undefined").must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
