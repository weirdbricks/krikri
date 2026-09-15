require "../spec_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("assert-undefined-register", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# The registered var for a CONDITIONAL-EVALUATION failure carries ONLY
# failed+msg - no `changed` key - because the conditional failed before
# any module ran. Live-verified against ansible-core 2.19 (bookworm
# podman differential run): both `assert: that: undef == 1` and the
# equivalent `when: undef == 1` register keys=['failed', 'msg'], so a
# later task reading `<reg>.changed` hits a genuine undefined (real
# Ansible's debug task there FAILS with "'dict object' has no attribute
# 'changed'"), while an ordinary failing assertion (the module ran and
# returned failed itself) still registers changed: false alongside
# assertion/evaluated_to. krikri used to stamp changed: false onto every
# conditional-error result (when_error_result, swallow_when_error, and
# assert's own undefined/non-bool rescues), so the later task saw
# changed=False where real Ansible errors - found via the podman-diff
# assert_edge_cases fixture (A1).
describe "conditional-evaluation failure register shape" do
  it "assert: that: with an undefined var registers no changed key" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undefined in that
            ansible.builtin.assert:
              that: "krikri_definitely_undefined == 1"
            register: a1
            ignore_errors: true
          - ansible.builtin.debug:
              msg: "A1 failed={{ a1.failed | default('undef') }} changed={{ a1.changed | default('undef') }}"
      YAML

    status.success?.should be_true
    output.should contain("A1 failed=True changed=undef")
    output.should_not contain("changed=False changed=undef")
  end

  it "when: with an undefined var registers no changed key" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undefined in when
            ansible.builtin.debug:
              msg: "hi"
            when: "krikri_definitely_undefined == 1"
            register: w1
            ignore_errors: true
          - ansible.builtin.debug:
              msg: "W1 failed={{ w1.failed | default('undef') }} changed={{ w1.changed | default('undef') }}"
      YAML

    status.success?.should be_true
    output.should contain("W1 failed=True changed=undef")
  end

  it "an ordinary failing assertion still registers changed: false" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: ordinary failing assert
            ansible.builtin.assert:
              that: "1 == 2"
            register: a2
            ignore_errors: true
          - ansible.builtin.debug:
              msg: "A2 failed={{ a2.failed }} changed={{ a2.changed }}"
      YAML

    status.success?.should be_true
    output.should contain("A2 failed=True changed=False")
  end
end
