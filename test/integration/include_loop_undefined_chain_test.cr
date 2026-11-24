require "../minitest_helper"

# Issue #62 - an undefined loop-source variable on a looped include_tasks:
# (`loop: "{{ ssls }}"` / `with_items: "{{ ssls }}"`, exphost.ssl_generator
# and melvin_suter.web_stack_deployment) must print the same [ERROR] chain
# block ("Task failed." + the task Origin, "<<< caused by >>>" with the
# inner variable's Origin pinned at the loop VALUE token) and the prefixed
# {"changed": false, "msg": "Task failed: ..."} fatal that the ordinary
# task path's loop-source resolution already produces - the old
# swallow_when_error path here printed a bare `fatal: ... => 'ssls' is
# undefined` with no chain block and no prefix. Verified live against
# ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("include-loop-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "looped include_tasks with an undefined loop source" do
  it "prints the Task failed chain block and prefixed fatal for loop:" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            loop: "{{ ssls }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: 'ssls' is undefined")
    output.must_include("Task failed.")
    output.must_include("<<< caused by >>>")
    # The cause block pins the Origin at the loop VALUE token, not the
    # task keyword.
    output.must_include("loop: \"{{ ssls }}\"")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'ssls' is undefined\"}")
    output.must_include("failed=1")
    output.wont_include("FAILED! => 'ssls' is undefined")
  end

  it "prints the same shape for with_items:" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            with_items: "{{ ssls }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: 'ssls' is undefined")
    output.must_include("<<< caused by >>>")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'ssls' is undefined\"}")
    output.must_include("failed=1")
  end

  # Issue #1743 - the loop source itself resolves, but an ITEM's own template
  # reads a variable nothing defines (t2d.ansible_role_libvirt_vm's
  # libvirt_vms default holds `name: "{{ libvirt_vm_name }}"`). Real
  # templates the whole list strictly before iterating, so the include fails
  # right there; krikri's lenient item render baked the "undefined" sentinel
  # into the item, loaded the file and ran to a green recap.
  it "fails on an undefined name inside a loop item's own template" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          libvirt_vms:
            - state: "{{ libvirt_vm_state }}"
              name: "{{ libvirt_vm_name }}"
          libvirt_vm_state:
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            with_items: "{{ libvirt_vms }}"
            loop_control:
              loop_var: vm
            when: (vm.state | default('present', true)) == 'present'
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: 'libvirt_vm_name' is undefined")
    output.must_include("<<< caused by >>>")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'libvirt_vm_name' is undefined\"}")
    output.wont_include("included:")
    output.wont_include("'undefined'")
    output.must_include("failed=1")
  end

  # Same undefined item, but the task-level when: is False without `item`
  # bound: real defers the loop templating error until the conditional has
  # had its say, so this is ONE bare skipping line (the items never existed,
  # hence no per-item lines) and skipped=1.
  it "skips once when the when: is false without item bound" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          libvirt_vms:
            - name: "{{ libvirt_vm_name }}"
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            with_items: "{{ libvirt_vms }}"
            when: flag | default(false)
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]\n")
    output.wont_include("(item=")
    output.wont_include("is undefined")
    output.must_include("skipped=1")
  end
end
