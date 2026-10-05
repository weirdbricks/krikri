require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

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
# evaluation, loop-source resolution) registers changed=false in
# ansible-core 2.19.11: the fatal line dumps {"changed": false, "msg":
# "Task failed: ..."} and the registered var reads back .changed as
# False (live-verified against ansible-playbook 2.19.11 for all
# three shapes below). An older 2.19 build showed a changed-less shape;
# 2.19.11 is the parity target.
describe "pre-module failure registered result shape" do
  it "fail msg with an undefined variable registers changed=false" do
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

    status.success?.must_equal(true)
    output.must_include("failed=True changed=False")
  end

  it "when: with an undefined variable registers changed=false" do
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

    status.success?.must_equal(true)
    output.must_include("failed=True changed=False")
  end

  it "undefined loop source registers changed=false" do
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

    status.success?.must_equal(true)
    output.must_include("failed=True changed=False")
  end
end
