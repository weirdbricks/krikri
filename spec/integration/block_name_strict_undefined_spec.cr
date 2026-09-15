require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook - the block-name
# keyword's strict-undefined behavior lives in TaskExecutor#substitute_
# block_name_chain (private, called from the "finalization of task args"
# block), so only a full run can prove both the failure and the success
# shapes end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "block: name keyword strict-undefined" do
  # ikke_t.podman_container_systemd (round 813203, via grafana_podman):
  # the role's tasks wrap everything in a block named
  # `do tasks when "{{ service_name }}" state is "running"`, whose
  # service_name default references `container_name` - defined only by
  # the grafana_podman wrapper role. Run standalone, real ansible-core
  # 2.19 fails the first block child with "Task failed: Error processing
  # keyword 'name': 'container_name' is undefined"; this engine rendered
  # the block name leniently for display and kept executing deep into
  # the role, diverging on every recap counter after.
  it "fails the first running child when the block name references an undefined variable" do
    playbook = File.tempname("block-name-strict-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: ok task
            ansible.builtin.debug:
              msg: hello
          - name: block with undefined "{{ service_name }}" in name
            block:
              - name: child debug
                ansible.builtin.debug:
                  msg: inside
              - name: never reached
                ansible.builtin.debug:
                  msg: two
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("Error processing keyword 'name'")
    output.to_s.should contain("'service_name' is undefined")
    # The failure is the CHILD's, not the block's own banner - and the
    # running child is where it lands, with everything after it gone.
    output.to_s.should contain("TASK [child debug]")
    output.to_s.should_not contain("never reached")
    output.to_s.should contain("failed=1")
  end

  # Live-verified against ansible-core 2.19.11: the block name is
  # finalized only for a child that actually goes to run, so a
  # when-false child sails through (counted skipped) and the failure
  # lands on the NEXT child that runs.
  it "lets a when-skipped child pass and fails the next running child" do
    playbook = File.tempname("block-name-when-child", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: block with undefined "{{ service_name }}" in name
            block:
              - name: skipped child
                ansible.builtin.debug:
                  msg: inside
                when: false
              - name: second child
                ansible.builtin.debug:
                  msg: two
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'service_name' is undefined")
    output.to_s.should contain("skipped=1")
    output.to_s.should contain("failed=1")
  end

  # A task's OWN name is lenient in real Ansible (banners as
  # "<< error 1 - 'nope' is undefined >>" and still runs/skips normally)
  # - only block names are strict.
  it "keeps a task's own undefined name lenient" do
    playbook = File.tempname("task-name-lenient", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: task with undefined "{{ nope }}" in name
            ansible.builtin.debug:
              msg: hi
          - name: second
            ansible.builtin.debug:
              msg: reached
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("reached")
    output.to_s.should_not contain("Error processing keyword 'name'")
  end

  # The strict substitute must report the INNERMOST missing name through
  # the recursive re-templating chain (block name -> service_name ->
  # container_name), exactly like real Ansible's one strict pass.
  it "reports the innermost undefined name through the re-templating chain" do
    playbook = File.tempname("block-name-innermost", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          service_name: "{{ container_name }}-container-pod.service"
        tasks:
          - name: block named after "{{ service_name }}"
            block:
              - name: child debug
                ansible.builtin.debug:
                  msg: inside
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'container_name' is undefined")
    output.to_s.should_not contain("'service_name' is undefined")
  end

  it "still runs the children when the block name renders cleanly" do
    playbook = File.tempname("block-name-defined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          service_name: grafana
        tasks:
          - name: block named after "{{ service_name }}"
            block:
              - name: child debug
                ansible.builtin.debug:
                  msg: inside
              - name: nested block after "{{ service_name }}"
                block:
                  - name: nested child
                    ansible.builtin.debug:
                      msg: nested
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("nested")
    output.to_s.should_not contain("Error processing keyword 'name'")
  end
end
