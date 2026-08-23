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

  # Follow-up (same investigation): the crash was fixed by having
  # when_passes? raise WhenEvaluationError instead of silently
  # swallowing it, but a LOOPED task's own per-item when_passes? calls
  # (execute_task_once, execute_looped_task_batched) originally still
  # treated a raise as an ordinary skip (returning nil for that item),
  # so the aggregate recap showed skipped=1 instead of real Ansible's
  # failed=1 ("One or more items failed"). Fixed by having those two
  # call sites build a real failed: true result instead of returning
  # nil, so finish_looped_task's own aggregation counts it correctly.
  it "aggregates a looped when: failure to failed=1, not skipped=1" do
    playbook = File.tempname("when-eval-error-loop", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mounts: []
        tasks:
          - name: looped, when raises
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: [a, b]
            when: (mounts | selectattr('mount', 'equalto', '/data') | list | first).device == item
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("failed: [localhost] => (item=a)")
    output.to_s.should contain("failed: [localhost] => (item=b)")
    output.to_s.should contain("failed=1")
    output.to_s.should_not contain("skipped=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "ignore_errors: on an ordinary (non-when-related) task failure" do
  # Real bug found while fixing the when: crash above: real Ansible
  # ALWAYS prints a bare "...ignoring" line right after any failed
  # task's output when ignore_errors: catches it (verified directly
  # against a real ansible-playbook run) - this engine never printed it
  # for an ordinary failure, only (after the fix above landed) for the
  # narrower when:-raises-an-exception case. Fixed in
  # ResultDisplay.display_result generally, not just for when:.
  it "prints ...ignoring the same way real Ansible does" do
    playbook = File.tempname("ignore-errors-normal", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: normal fail ignored
            ansible.builtin.fail:
              msg: boom
            ignore_errors: true
          - name: after
            ansible.builtin.debug:
              msg: still runs
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("...ignoring")
    output.to_s.should contain("ignored=1")
    output.to_s.should contain("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
