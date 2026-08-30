require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

describe "ansible_check_mode magic var" do
  it "is false on a real run and true under --check, not undefined" do
    # Real bug found benchmarking geerlingguy.apache-php-fpm (round 164,
    # right after ansible_version's own round163 fix - same bug class):
    # ansible_check_mode (real Ansible magic var, true under --check,
    # false on a real run) was entirely unimplemented. Real-world role
    # idioms reference it directly (`when: not ansible_check_mode`,
    # `changed_when: not ansible_check_mode`) - a bare lookup that always
    # resolved to this engine's "undefined" sentinel, hard-failing under
    # 0.9.517's strict module-arg templating.
    playbook = File.tempname("ansible-check-mode", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: show it
            ansible.builtin.debug:
              msg: "check_mode is {{ ansible_check_mode }}"
      YAML

    normal_output = IO::Memory.new
    normal_status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: normal_output, error: normal_output)
    normal_status.success?.should be_true
    normal_output.to_s.should contain("check_mode is False")
    normal_output.to_s.should_not contain("is undefined")

    check_output = IO::Memory.new
    check_status = Process.run(BINARY, ["--check", "-i", INVENTORY, playbook], output: check_output, error: check_output)
    check_status.success?.should be_true
    check_output.to_s.should contain("check_mode is True")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
