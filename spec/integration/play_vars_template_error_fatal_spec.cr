require "file_utils"
require "../spec_helper"

# A templating error raised while resolving a play's own `vars:` (e.g. a
# folded `>-` scalar whose expression fails when the var is finally read)
# is fatal to the ENTIRE playbook run in real Ansible, not an ordinary
# per-host failure: every host that reads the bad var fails, and once
# every host of the play's (serial) batch has failed,
# PlaybookExecutor.run's per-batch check aborts the whole run - no
# subsequent play executes at all, even one targeting an unrelated group
# (verified against ansible-core 2.19.11: both the templating-error shape
# and an ordinary module failure across the whole batch stop the run
# before the second play's PLAY banner; a failure that leaves part of the
# batch healthy still lets the second play run).
#
# krikri used to treat the same failure as a plain per-host result and
# carried straight on into plays that didn't depend on the broken var -
# exactly the "kept executing against production" hazard.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_two_play_playbook(play1_body : String) : {Int32, String}
  dir = File.tempname("vars-fatal")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[backend_nodes]\nh1 ansible_connection=local\nh2 ansible_connection=local\n\n" \
    "[some_other_group]\nh3 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: backend_nodes
      gather_facts: false
      vars:
        expected_ips: >-
          {{ groups['backend_nodes'] | default([])
             | map('extract', hostvars, 'missing_attr')
             | list | sort }}
      tasks:
    #{play1_body}
    - hosts: some_other_group
      gather_facts: false
      tasks:
        - name: unrelated task
          ansible.builtin.debug:
            msg: "SECOND-PLAY-RAN"
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "a play vars: templating error" do
  # The headline scenario: the var is read on every host of play 1, so
  # the whole batch fails and the run must abort before play 2.
  it "aborts the whole run before the second play when every host reads it" do
    code, output = run_two_play_playbook(<<-YAML)
          - name: read the bad var
            ansible.builtin.debug:
              var: expected_ips
          - name: later task
            ansible.builtin.debug:
              msg: "LATER-TASK"
      YAML

    code.should eq(2)
    output.should contain("PLAY [backend_nodes]")
    output.should_not contain("PLAY [some_other_group]")
    output.should_not contain("SECOND-PLAY-RAN")
    output.should contain("failed=1")
  end

  # Same expression read through a task-arg template (the read path real
  # ansible-core 2.19.11 fails hard on locally: "Finalization of task
  # args ... failed") - same whole-run abort.
  it "aborts the whole run when the bad var is read through task args" do
    code, output = run_two_play_playbook(<<-YAML)
          - name: read the bad var
            ansible.builtin.debug:
              msg: "ips: {{ expected_ips }}"
      YAML

    code.should eq(2)
    output.should contain("PLAY [backend_nodes]")
    output.should_not contain("PLAY [some_other_group]")
    output.should_not contain("SECOND-PLAY-RAN")
  end

  # Only h1 reads the bad var; h2 stays healthy, so the batch is not
  # fully failed and the second play still runs - per-host failure
  # semantics for the partial case, exactly as real Ansible.
  it "lets the second play run when only part of the batch reads it" do
    _code, output = run_two_play_playbook(<<-YAML)
          - name: read the bad var on h1 only
            ansible.builtin.debug:
              var: expected_ips
            when: inventory_hostname == 'h1'
      YAML

    output.should contain("PLAY [some_other_group]")
    output.should contain("SECOND-PLAY-RAN")
  end

  # The abort rule is cause-agnostic in real Ansible: an ordinary module
  # failure across the whole batch stops the run the same way.
  it "aborts before the second play on an ordinary all-host module failure too" do
    dir = File.tempname("vars-fatal-mod")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"),
      "[backend_nodes]\nh1 ansible_connection=local\nh2 ansible_connection=local\n\n" \
      "[some_other_group]\nh3 ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: backend_nodes
        gather_facts: false
        tasks:
          - name: ordinary failure
            ansible.builtin.command: /bin/false
      - hosts: some_other_group
        gather_facts: false
        tasks:
          - name: unrelated task
            ansible.builtin.debug:
              msg: "SECOND-PLAY-RAN"
      YAML

    stdout_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
      output: stdout_io, error: stdout_io, chdir: dir)
    status.exit_code.should eq(2)
    stdout_io.to_s.should_not contain("SECOND-PLAY-RAN")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
