require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against real playbooks: the bug is about the
# registered variable a later task's when: sees, which only exists after a
# full parse+execute pass through TaskExecutor's include paths.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "register: on an include_tasks:/include_role: statement" do
  it "defines the variable for a later when:, so the dependent task runs" do
    # Issue #888: the include-family parsers returned before the main
    # parse path's register: handling, so the name stayed undefined and
    # every later `when: reg is succeeded` failed argument evaluation
    # where ansible-playbook recaps ok=N+1 failed=0 (live-verified vs
    # 2.19.11).
    tasks_file = File.tempname("include-register-tasks", ".yml")
    File.write(tasks_file, <<-YAML)
      - ansible.builtin.debug:
          msg: from included
      YAML
    playbook = File.tempname("include-register-when", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks:
              file: #{tasks_file}
            register: include_reg
          - ansible.builtin.debug:
              msg: after
            when: include_reg is succeeded
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(%("msg": "after"))
    output.to_s.must_match(/ok=3\s+changed=0\s+.*failed=0/)
  ensure
    File.delete(tasks_file) if tasks_file && File.exists?(tasks_file)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers the include's own result shape, matching Ansible's include/include_args keys" do
    tasks_file = File.tempname("include-register-shape-tasks", ".yml")
    File.write(tasks_file, "- ansible.builtin.debug:\n    msg: x\n")
    playbook = File.tempname("include-register-shape", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks:
              file: #{tasks_file}
            register: include_reg
          - ansible.builtin.debug:
              var: include_reg
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(%("changed": false))
    output.to_s.must_include(%("include": #{tasks_file.inspect}))
    output.to_s.must_include(%("include_args": {}))
  ensure
    File.delete(tasks_file) if tasks_file && File.exists?(tasks_file)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers the skip shape when the include's when: is false" do
    tasks_file = File.tempname("include-register-skip-tasks", ".yml")
    File.write(tasks_file, "- ansible.builtin.debug:\n    msg: never\n")
    playbook = File.tempname("include-register-skip", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks:
              file: #{tasks_file}
            register: skip_reg
            when: false
          - ansible.builtin.debug:
              var: skip_reg
          - ansible.builtin.debug:
              msg: saw the skip
            when: skip_reg is skipped
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(%("msg": "saw the skip"))
    output.to_s.must_include(%("skip_reason": "Conditional result was False"))
  ensure
    File.delete(tasks_file) if tasks_file && File.exists?(tasks_file)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers the failed result of an unconvertible bool keyword, so a later when: skips" do
    # Issue #1275: real converts the bool keywords before resolving the
    # role, fails the task on rolespec_validate even when an earlier
    # keyword (public:) is convertible, and registers the failed result -
    # so `when: reg is succeeded` skips where krikri failed it as
    # "'reg' is undefined" (live-verified vs 2.21.6 in and out of --check).
    src_dir = File.tempname("include-register-boolkw")
    Dir.mkdir_p(File.join(src_dir, "roles", "kpg_boolkw_role", "tasks"))
    File.write(File.join(src_dir, "roles", "kpg_boolkw_role", "tasks", "main.yml"), <<-YAML)
      - ansible.builtin.debug:
          msg: never runs
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_role:
              name: kpg_boolkw_role
              public: true
              rolespec_validate: bluqcw
            register: role_reg
            ignore_errors: true
          - ansible.builtin.debug:
              var: role_reg
          - ansible.builtin.debug:
              msg: ran
            when: role_reg is succeeded
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    status.success?.must_equal(true)
    output.to_s.must_include(%("failed": true))
    output.to_s.must_include(
      %("msg": "Task failed: Error processing keyword 'rolespec_validate': The value 'bluqcw' could not be converted to 'bool'."))
    output.to_s.wont_include(%("msg": "never runs"))
    output.to_s.wont_include(%("msg": "ran"))

    [["--check"], [] of String].each do |extra|
      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY] + extra + [playbook],
        output: output, error: output, chdir: src_dir)
      status.success?.must_equal(true)
      output.to_s.wont_include(%("msg": "ran"))
      output.to_s.must_match(/failed=0\s+skipped=1\s+rescued=0\s+ignored=1/)
    end
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "registers the include_role's include_args with the rendered role name" do
    # Same layout the other role integration specs use: a tempdir with a
    # roles/ subtree next to the playbook, so the role resolves without any
    # roles-path plumbing.
    src_dir = File.tempname("include-register-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "kpg_register_role", "tasks"))
    File.write(File.join(src_dir, "roles", "kpg_register_role", "tasks", "main.yml"), <<-YAML)
      - ansible.builtin.debug:
          msg: inside role
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          role_name_var: kpg_register_role
        tasks:
          - ansible.builtin.include_role:
              name: "{{ role_name_var }}"
            register: role_reg
          - ansible.builtin.debug:
              var: role_reg
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include(%("include_args": {))
    output.to_s.must_include(%("name": "kpg_register_role"))
    # The RENDERED role name, not the template text (live-verified vs
    # 2.19.11).
    output.to_s.wont_include(%("name": "{{ role_name_var }}"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "registers a failed include_role so a later when: sees it as unsucceeded" do
    # Issue #1274: a bad rolespec_validate fails the include_role task, and
    # real registers that failure like any other task's
    # (live-verified vs 2.21.6) - {failed: true, msg: ...} - so a
    # `when: reg is succeeded` on the next task SKIPS instead of erroring
    # out on an undefined name. The convertible public:/allow_duplicates:
    # here are what used to stop the keyword conversion scan early.
    src_dir = File.tempname("include-register-role-failed")
    Dir.mkdir_p(File.join(src_dir, "roles", "kpg_register_role", "tasks"))
    File.write(File.join(src_dir, "roles", "kpg_register_role", "tasks", "main.yml"), <<-YAML)
      - ansible.builtin.debug:
          msg: never runs
      YAML
    tasks_file = File.join(src_dir, "included.yml")
    File.write(tasks_file, "- ansible.builtin.debug:\n    msg: never includes\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_role:
              allow_duplicates: true
              name: kpg_register_role
              public: true
              rolespec_validate: bluqcw
            register: role_reg
            ignore_errors: true
          - ansible.builtin.include_tasks:
              file: #{tasks_file}
            when: role_reg is succeeded
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include(%("msg": "Task failed: Error processing keyword 'rolespec_validate'))
    output.to_s.wont_include("never runs")
    output.to_s.wont_include("never includes")
    output.to_s.wont_include("is undefined")
    output.to_s.must_match(/ok=1\s+changed=0\s+.*failed=0\s+skipped=1/)
    output.to_s.must_match(/ignored=1/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end
