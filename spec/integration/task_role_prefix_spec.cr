require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks, since role-name
# prefixing is entirely a TASK[]/HANDLER[] banner display concern in
# executor.cr/handler_runner.cr - not reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Found while fixing the "Generic TASK [Task 1] label on a nameless
# task" gap: TASK[]/HANDLER[] banners never carried the owning role's
# name at all (named or nameless tasks alike), unlike real Ansible's
# own `TASK [role : task name]` convention - verified live against
# ansible-core 2.19.12. See KNOWN_MISSING.md's own (now-fixed) writeup.
describe "role-name prefix on TASK[]/HANDLER[] banners" do
  it "prefixes a role's own named and nameless tasks, but not a play-level task" do
    src_dir = File.tempname("task-role-prefix-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: a named task
        ansible.builtin.debug:
          msg: hi
      - ansible.builtin.debug:
          msg: bye
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
        tasks:
          - name: play level task
            ansible.builtin.debug:
              msg: play
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("TASK [myrole : a named task]")
    output.to_s.should contain("TASK [myrole : ansible.builtin.debug]")
    output.to_s.should contain("TASK [play level task]")
    output.to_s.should_not contain("TASK [myrole : play level task]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "does not prefix a named include_role: task with its OWN enclosing role, but does prefix what it expands into" do
    src_dir = File.tempname("task-role-prefix-include-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: include the nested role
        include_role:
          name: inner
      YAML
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: nested role task
        ansible.builtin.debug:
          msg: nested
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("TASK [include the nested role]")
    output.to_s.should_not contain("TASK [outer : include the nested role]")
    output.to_s.should contain("TASK [inner : nested role task]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefixes a role handler's HANDLER banner without breaking a plain notify: match" do
    src_dir = File.tempname("task-role-prefix-handler")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "handlers"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: trigger
        ansible.builtin.debug:
          msg: hi
        changed_when: true
        notify: my handler
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "handlers", "main.yml"), <<-YAML)
      - name: my handler
        ansible.builtin.debug:
          msg: handled
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("HANDLER [myrole : my handler]")
    output.to_s.should contain("handled")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
