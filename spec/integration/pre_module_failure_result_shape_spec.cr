require "../spec_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("pre-module-failure-shape", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# A failure raised BEFORE any module runs (param templating, when:
# evaluation, loop-source resolution) registers a msg-only result in
# real ansible-core: no "changed" key at all, because there is no
# module result to carry one. Live-verified against real ansible-core
# 2.19 (fail_edge_cases.yml F2/F6/F7 in the podman-diff harness).
describe "pre-module failure registered result shape" do
  it "fail msg with an undefined variable registers no changed key" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fail with undefined msg var
            ansible.builtin.fail:
              msg: "boom {{ no_such_var_zzz }}"
            register: f2
            ignore_errors: true
          - name: show registered shape
            ansible.builtin.debug:
              msg: "failed={{ f2.failed | default('none') }} changed={{ f2.changed | default('none') }}"
      YAML

    status.success?.should be_true
    output.should contain("failed=True changed=none")
  end

  it "when: with an undefined variable registers no changed key" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: when with undefined var
            ansible.builtin.command: echo hi
            register: f6
            when: no_such_var_zzz | bool
            ignore_errors: true
          - name: show registered shape
            ansible.builtin.debug:
              msg: "failed={{ f6.failed | default('none') }} changed={{ f6.changed | default('none') }}"
      YAML

    status.success?.should be_true
    output.should contain("failed=True changed=none")
  end

  it "undefined loop source registers no changed key" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: loop with undefined source
            ansible.builtin.command: echo "{{ item }}"
            register: f7
            loop: "{{ no_such_list_zzz }}"
            ignore_errors: true
          - name: show registered shape
            ansible.builtin.debug:
              msg: "failed={{ f7.failed | default('none') }} changed={{ f7.changed | default('none') }}"
      YAML

    status.success?.should be_true
    output.should contain("failed=True changed=none")
  end
end
