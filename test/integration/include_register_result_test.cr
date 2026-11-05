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
end
