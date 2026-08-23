require "../spec_helper"

# Runs the compiled binary against real playbooks (not --check mode),
# since this bug is specifically about #when_passes? crashing the whole
# PROCESS with an unhandled exception rather than failing just the one
# task - not reachable from a unit spec without a live TaskExecutor run.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "when: evaluation raising an exception" do
  # Real bug found while auditing previously-documented-but-unfixed
  # gaps: `mounts | selectattr(...) | first` on an empty match (the
  # exact shape from robertdebock.mount_options, round140) already
  # raised correctly inside `{{ }}` module-arg templating (a clean
  # failed task, matching real Ansible - fixed earlier via
  # substitute_task_params's own rescue), but the IDENTICAL expression
  # used inside a bare when: condition instead crashed the entire
  # process with an unhandled Crystal exception and stack trace -
  # #when_passes? (7 call sites: solo/looped/batched tasks and meta:)
  # had no rescue at all. Real ansible-playbook degrades to one clean
  # failed task ("Task failed: Error while evaluating conditional:
  # ...") and continues/exits normally.
  it "fails the task cleanly instead of crashing the whole process" do
    playbook = File.tempname("when-eval-error", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: raises during when
            ansible.builtin.debug:
              msg: should not print
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == 'x'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("Error while evaluating conditional")
    output.to_s.should contain("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "honors ignore_errors: - ok+ignored, not failed, host not halted" do
    playbook = File.tempname("when-eval-error-ignored", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: raises during when, ignored
            ansible.builtin.debug:
              msg: should not print
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == 'x'
            ignore_errors: true
          - name: still runs
            ansible.builtin.debug:
              msg: still runs
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("still runs")
    output.to_s.should contain("...ignoring")
    output.to_s.should contain("ignored=1")
    output.to_s.should contain("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
