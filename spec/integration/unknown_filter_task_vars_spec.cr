require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook - an unknown filter
# inside a task's OWN `vars:` block surfaces in TaskExecutor#build_vars_
# context (render_task_vars re-raises it), not in the main task-body
# param substitution whose rescue already degrades cleanly, so only a
# live TaskExecutor run can prove the process survives it.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "unknown filter in a task's own vars: block" do
  # nephelaiio.pip / nephelaiio.gitlab's own `nephelaiio.plugins.sorted_get`
  # inside a set_fact task's vars: block: krikri detected the unknown filter
  # and raised the right error, but nothing between render_task_vars and
  # krikri-playbook's top-level run caught it, so the whole process crashed
  # with an unhandled Crystal exception. Real ansible-playbook fails just
  # that task ("No filter named 'X'.") and recaps failed=1.
  it "fails the task cleanly instead of crashing the whole process" do
    playbook = File.tempname("unknown-filter-task-vars", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: task with unknown filter in its own vars
            ansible.builtin.debug:
              msg: should never print
            vars:
              sorted: "{{ 'abc' | nephelaiio.plugins.sortedget }}"
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("No filter named 'nephelaiio.plugins.sortedget'.")
    output.to_s.should contain("failed=1")
  end
end

# stackhpc.luks's shape: an unknown (role-local, e.g. luks_key) filter
# referenced from a `vars:` block on an include_tasks: STATEMENT itself.
# The include dispatches to the include_tasks paths in executor_blocks_
# includes.cr before execute_task's generic build_vars_context rescue
# (0.9.885) is ever reached, so neither include path caught the raise and
# the whole process crashed with an unhandled exception. Real
# ansible-playbook fails just the include task ("No filter named 'X'.")
# and recaps failed=1.
private def write_include_playbook(dir : String, extra_task_keys : String) : String
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "included.yml"), <<-YAML)
    - name: included task
      ansible.builtin.debug:
        msg: included ran
  YAML
  playbook = File.join(dir, "playbook.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: include with unknown filter in its own vars
          ansible.builtin.include_tasks: included.yml
          #{extra_task_keys}
          vars:
            key: "{{ 'abc' | luks_key }}"
        - name: after
          ansible.builtin.debug:
            msg: still running
  YAML
  playbook
end

describe "unknown filter in an include_tasks: statement's own vars: block" do
  it "fails the include task cleanly instead of crashing (multi-host batched include path)" do
    playbook = write_include_playbook(File.tempname("unknown-filter-include-tasks-multi"), "")
    dir = File.dirname(playbook)

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("No filter named 'luks_key'.")
    output.to_s.should contain("failed=1")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "fails the include task cleanly instead of crashing (solo include path, looped include)" do
    playbook = write_include_playbook(File.tempname("unknown-filter-include-tasks-solo"), "loop:\n            - 1")
    dir = File.dirname(playbook)

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should contain("No filter named 'luks_key'.")
    output.to_s.should contain("failed=1")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
