require "../spec_helper"
require "file_utils"

# 0.9.548 wired ConditionalEvaluator.evaluate's raise_undefined: true
# strict-undefined case into exactly one when: call site
# (Executor#when_passes?, for a plain task) because that was the only
# one already exception-safe (WhenEvaluationError, see 40671ba). This
# spec covers the five OTHER call sites getting the same treatment:
# partition_by_when (multi-host block:/include_tasks:), execute_block
# (single-host block:), run_include_tasks_once, run_include_role_once,
# and execute_handler_plugin_once (handler when:). Each site must:
#   1. fail cleanly (not crash) when its own when: reaches a genuinely
#      undefined bare/dotted variable, and
#   2. stay lenient when the same undefined variable instead goes
#      through a filter/default() chain - scope must not widen beyond
#      0.9.548's own REGEX_BARE_VAR_REF-shaped boundary.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, inventory : String = INVENTORY)
  playbook = File.tempname("when-strict-five-sites", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "strict-undefined when: - partition_by_when (multi-host block:)" do
  it "fails only the host whose when: reaches a genuinely undefined var, leaves the other host unaffected" do
    inventory = File.tempname("when-strict-multi-inventory", ".ini")
    File.write(inventory, <<-INI)
      hostone ansible_connection=local myvar=x
      hosttwo ansible_connection=local
      INI

    status, output = run_playbook(<<-YAML, inventory)
      - hosts: all
        gather_facts: false
        tasks:
          - name: gated block
            when: myvar == 'x'
            block:
              - name: inner task
                ansible.builtin.debug:
                  msg: "ran on host"
      YAML

    status.success?.should be_false
    output.should_not contain("Unhandled exception")
    output.should contain("Error while evaluating conditional")
    # hostone (myvar=x) ran the block normally; hosttwo (myvar undefined) failed cleanly.
    output.should contain("hostone")
    output.should contain("hosttwo")
    output.should contain("failed=1")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
  end

  it "stays lenient (skips, doesn't fail) when the undefined var goes through default()" do
    inventory = File.tempname("when-strict-multi-inventory-lenient", ".ini")
    File.write(inventory, <<-INI)
      hostone ansible_connection=local
      hosttwo ansible_connection=local
      INI

    status, output = run_playbook(<<-YAML, inventory)
      - hosts: all
        gather_facts: false
        tasks:
          - name: gated block
            when: myvar | default('') == 'x'
            block:
              - name: inner task
                ansible.builtin.debug:
                  msg: "ran on host"
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should contain("failed=0")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
  end
end

describe "strict-undefined when: - execute_block (single-host block:)" do
  it "fails the block cleanly instead of crashing, for a genuinely undefined bare var" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated block
            when: totally_undefined_var == 'x'
            block:
              - name: inner task
                ansible.builtin.debug:
                  msg: "should not print"
      YAML

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.should_not contain("Unhandled exception")
    output.should_not contain("should not print")
    output.should contain("Error while evaluating conditional")
    output.should contain("failed=1")
  end

  it "stays lenient (skips, doesn't fail) when the undefined var goes through default()" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated block
            when: totally_undefined_var | default('') == 'x'
            block:
              - name: inner task
                ansible.builtin.debug:
                  msg: "should not print"
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should_not contain("should not print")
    output.should contain("skipping:")
    output.should contain("failed=0")
  end

  # A block's when: is INHERITED by each child, so a condition that
  # raises is re-evaluated (and re-raised) once per child task rather
  # than failing the block as a unit. Live-verified against real
  # ansible-core 2.19.12 on Rocky 9.6 (round173): the first task of
  # block: fails, the rest of that list is skipped by the halt, and
  # always: STILL runs and fails the same way => failed=2.
  it "fails block: and always: separately (failed=2), matching real Ansible's when: inheritance" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated block
            when: totally_undefined_var
            block:
              - name: block one
                ansible.builtin.debug:
                  msg: "should not print"
              - name: block two
                ansible.builtin.debug:
                  msg: "should not print either"
            always:
              - name: always one
                ansible.builtin.debug:
                  msg: "always body should not print"
      YAML

    status.exit_code.should eq(2)
    output.should_not contain("Unhandled exception")
    output.should_not contain("should not print")
    output.should_not contain("always body should not print")
    # Both "block one" and "always one" fail on the same condition;
    # "block two" never runs (the halt from "block one" skips it).
    output.should contain("failed=2")
  end

end

describe "strict-undefined when: - run_include_tasks_once (include_tasks:)" do
  it "fails cleanly for a genuinely undefined bare var gating the include" do
    src_dir = File.tempname("when-strict-include-tasks")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "inner.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: "should not print"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated include
            when: totally_undefined_var == 'x'
            ansible.builtin.include_tasks: inner.yml
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should_not contain("should not print")
    output.to_s.should contain("Error while evaluating conditional")
    output.to_s.should contain("failed=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "stays lenient (skips, doesn't fail) when the undefined var goes through default()" do
    src_dir = File.tempname("when-strict-include-tasks-lenient")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "inner.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: "should not print"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated include
            when: totally_undefined_var | default('') == 'x'
            ansible.builtin.include_tasks: inner.yml
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("Error while evaluating conditional")
    output.to_s.should_not contain("should not print")
    output.to_s.should contain("skipping:")
    output.to_s.should contain("failed=0")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end

describe "strict-undefined when: - run_include_role_once (include_role:)" do
  it "fails cleanly for a genuinely undefined bare var gating the include" do
    src_dir = File.tempname("when-strict-include-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: "should not print"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated include_role
            when: totally_undefined_var == 'x'
            ansible.builtin.include_role:
              name: inner
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.to_s.should_not contain("Unhandled exception")
    output.to_s.should_not contain("should not print")
    output.to_s.should contain("Error while evaluating conditional")
    output.to_s.should contain("failed=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "stays lenient (skips, doesn't fail) when the undefined var goes through default()" do
    src_dir = File.tempname("when-strict-include-role-lenient")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: "should not print"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated include_role
            when: totally_undefined_var | default('') == 'x'
            ansible.builtin.include_role:
              name: inner
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("Error while evaluating conditional")
    output.to_s.should_not contain("should not print")
    output.to_s.should contain("skipping:")
    output.to_s.should contain("failed=0")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end

describe "strict-undefined when: - execute_handler_plugin_once (handler when:)" do
  it "fails the handler cleanly for a genuinely undefined bare var" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger handler
            ansible.builtin.debug:
              msg: triggering
            changed_when: true
            notify: gated handler
        handlers:
          - name: gated handler
            when: totally_undefined_var == 'x'
            ansible.builtin.debug:
              msg: "should not print"
      YAML

    status.success?.should be_false
    status.exit_code.should eq(2)
    output.should_not contain("Unhandled exception")
    output.should_not contain("should not print")
    output.should contain("Error while evaluating conditional")
    output.should contain("failed=1")
  end

  it "stays lenient (skips, doesn't fail) when the undefined var goes through default()" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger handler
            ansible.builtin.debug:
              msg: triggering
            changed_when: true
            notify: gated handler
        handlers:
          - name: gated handler
            when: totally_undefined_var | default('') == 'x'
            ansible.builtin.debug:
              msg: "should not print"
      YAML

    status.success?.should be_true
    output.should_not contain("Error while evaluating conditional")
    output.should_not contain("should not print")
    output.should contain("skipping:")
    output.should contain("failed=0")
  end
end
