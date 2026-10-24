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

  it "keeps the three-level chain for a plain-scalar task name ending with a quote char" do
    tempdir = File.tempname("final-block-quote").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "blockrole3")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - blockrole3
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Defining DC/OS by using 'version' or, more specifically, 'image_commit'
        ansible.builtin.set_fact:
          pkg: "{{ __role_pkg }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'pkg': '__role_pkg' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{tasks_file}:1:3")
    text.must_include("\n<<< caused by >>>\n\nFinalization of task args for 'ansible.builtin.set_fact' failed.\nOrigin: #{tasks_file}:2:3")
    text.must_include("Error while resolving value for 'pkg': '__role_pkg' is undefined\nOrigin: #{tasks_file}:3:10")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'pkg': '__role_pkg' is undefined\"}")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "points a next-line k=v string's undefined key at the folded string's start, not the module key (issue #311)" do
    tempdir = File.tempname("final-block-kv-fold").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "deluserfoldrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - deluserfoldrole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: delete user
        user:#{" "}
          name={{ delete_user }}
          state=absent
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # ansible-core 2.19.11: the k=v string folds whole after the empty
    # module value, so the innermost stanza's Origin is the string's first
    # character (4:5, context lines 2-4, caret under `name=`); krikri
    # pointed the same stanza at the module key (3:3) instead.
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.user' failed: Error while resolving value for 'name': 'delete_user' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{tasks_file}:2:3")
    text.must_include("\nFinalization of task args for 'ansible.builtin.user' failed.\nOrigin: #{tasks_file}:3:3")
    text.must_include("Error while resolving value for 'name': 'delete_user' is undefined\nOrigin: #{tasks_file}:4:5\n")
    text.must_include("2 - name: delete user\n3   user: \n4     name={{ delete_user }}\n      ^ column 5\n")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.user' failed: Error while resolving value for 'name': 'delete_user' is undefined"}))
    status.exit_code.must_equal(2)
    output.to_s.must_match(/failed=1/)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
