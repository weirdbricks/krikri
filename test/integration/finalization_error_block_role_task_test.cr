require "../minitest_helper"
require "file_utils"

# Task-arg finalization failures on tasks defined in a ROLE (or otherwise
# include-sourced) file: ansible-core 2.19.11 prints the same three-level
# [ERROR] chain block as for playbook tasks, with Origin pointing into the
# task's OWN file (live-captured on supertarto.mariadb / OndrejHome.targetcli
# in the 600-role round). Before the fix, krikri scanned the top-level
# playbook file with the role task's line numbers - falling off the end
# (Index out of bounds) instead of printing the block, and the stray
# exception inside include_tasks execution even surfaced as a bogus
# "Failed to load included tasks: Index out of bounds" failure.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (role-sourced tasks)" do
  it "prints the three-level block with role-file origins for a named role task" do
    tempdir = File.tempname("final-block-role").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "blockrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - blockrole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Set the default package
        ansible.builtin.set_fact:
          pkg: "{{ __role_pkg }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Error while resolving value for 'pkg': '__role_pkg' is undefined")
    text.must_include("Origin: #{tasks_file}:1:3")
    text.must_include("Origin: #{tasks_file}:2:3")
    text.must_include("Origin: #{tasks_file}:3:10")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'pkg': '__role_pkg' is undefined\"}")
    text.wont_include("Index out of bounds")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "does not turn the emitted block's stray exception into a bogus include failure" do
    tempdir = File.tempname("final-block-include").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "blockrole2")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks: roles/blockrole2/tasks/main.yml
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: Broken fact
        ansible.builtin.set_fact:
          pkg: "{{ __role_pkg2 }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Error while resolving value for 'pkg': '__role_pkg2' is undefined")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed))
    text.wont_include("Failed to load included tasks: Index out of bounds")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
