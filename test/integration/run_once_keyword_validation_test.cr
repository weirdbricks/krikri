require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")
private MULTI_HOST   = File.join(__DIR__, "..", "fixtures", "inventory-three-local-hosts.ini")

# Issue #1444: ansible post-validates the run_once: keyword with its strict
# boolean() when the task runs, so a value it cannot convert fails that task
# with "Error processing keyword 'run_once'" instead of running it. The
# keyword is inherited from the play, so a play-level value fails the play's
# first task that is not skipped, with the chain's lower links Origin'd at
# the play's own value token.
describe "run_once: keyword post-validation" do
  it "fails the first task on an unconvertible play-level run_once: value" do
    playbook = File.tempname("run-once-play-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Invalid play run_once keyword
            ansible.builtin.debug:
              msg: INVALID-RUN-ONCE-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    # The failing task's own Origin, then the play's value token for both
    # lower chain links.
    output_text.must_include("Origin: #{File.expand_path(playbook)}:6:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:13")
    output_text.must_match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a task with its own unconvertible run_once: value" do
    playbook = File.tempname("run-once-task-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Invalid task run_once keyword
            ansible.builtin.debug:
              msg: INVALID-RUN-ONCE-RAN
            run_once: kpg-maybe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:5:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:8:17")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "runs a play-level run_once: task on the first host only, unless a task opts out" do
    playbook = File.tempname("run-once-play-valid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: threelocal
        gather_facts: false
        run_once: true
        tasks:
          - name: Play-level run_once
            ansible.builtin.debug:
              msg: "PLAY-LEVEL {{ inventory_hostname }}"
          - name: Opting out
            ansible.builtin.debug:
              msg: "OPTED-OUT {{ inventory_hostname }}"
            run_once: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", MULTI_HOST, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.must_include("PLAY-LEVEL nodea")
    output_text.wont_include("PLAY-LEVEL nodeb")
    # The task's own run_once: false still wins over the play's value.
    output_text.must_include("OPTED-OUT nodeb")
    output_text.must_include("OPTED-OUT nodec")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a dynamic include_role: statement on an unconvertible inherited run_once:" do
    dir = write_include_fixtures("run-once-include-role")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Dynamic include
            ansible.builtin.include_role:
              name: r1
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    # The only task fails under ignore_errors:, so the run itself succeeds.
    status.success?.must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    # The include statement itself fails, so the role never loads.
    output_text.wont_include("included: r1")
    output_text.wont_include(%("msg": "ROLE-TASK-RAN"))
    output_text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'run_once'))
    output_text.must_include("...ignoring")
    output_text.must_match(/ignored=1\b/)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "fails a dynamic include_tasks: statement on an unconvertible inherited run_once:" do
    dir = write_include_fixtures("run-once-include-tasks")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Dynamic include
            ansible.builtin.include_tasks:
              file: included.yml
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("included:")
    output_text.wont_include(%("msg": "INCLUDED-TASK-RAN"))
    output_text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'run_once'))
    output_text.must_match(/ignored=1\b/)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "fails an include_vars: statement on an unconvertible inherited run_once:" do
    dir = write_include_fixtures("run-once-include-vars")
    File.write(File.join(dir, "vars.yml"), "some_var: 1\n")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Include vars
            ansible.builtin.include_vars:
              file: vars.yml
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    # The keyword error replaces the action's own result line.
    output_text.wont_include("ok: [localhost]")
    output_text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Error processing keyword 'run_once'))
    output_text.must_match(/ignored=1\b/)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "fails an imported role's first task on an unconvertible inherited run_once:" do
    dir = write_include_fixtures("run-once-import-role")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Static import
            ansible.builtin.import_role:
              name: r1
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    # A static import is not post-validated itself in real; the value
    # rides down to the role's own tasks, whose first one fails with the
    # chain Origin'd at the play's value token.
    output_text.must_include("TASK [r1 : role task]")
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include(%("msg": "ROLE-TASK-RAN"))
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:13")
    output_text.must_match(/failed=1\b/)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "runs an imported role's tasks on the first host only under a play-level run_once: true" do
    dir = write_include_fixtures("run-once-import-role-valid")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: threelocal
        gather_facts: false
        run_once: true
        tasks:
          - name: Static import
            ansible.builtin.import_role:
              name: r1
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", MULTI_HOST, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.scan("ROLE-TASK-RAN").size.must_equal(1)
    output_text.must_include("ok: [nodea]")
    output_text.wont_include("ok: [nodeb]")
    output_text.wont_include("ok: [nodec]")
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "runs a run_once: true include_role: statement on the first host only" do
    dir = write_include_fixtures("run-once-include-role-statement")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: threelocal
        gather_facts: false
        tasks:
          - name: Dynamic include
            ansible.builtin.include_role:
              name: r1
            run_once: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", MULTI_HOST, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.scan("included: r1 for").size.must_equal(1)
    output_text.must_include("included: r1 for nodea")
    output_text.scan("ROLE-TASK-RAN").size.must_equal(1)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "reports check_mode: before diff: when both are unconvertible" do
    playbook = File.tempname("run-once-keyword-order", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Both keywords unconvertible
            ansible.builtin.debug:
              msg: KEYWORD-ORDER-RAN
            check_mode: banana
            diff: banana
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'check_mode': The value 'banana' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("Error processing keyword 'diff'")
    output_text.wont_include(%("msg": "KEYWORD-ORDER-RAN"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# The include-family fixtures: a one-task role, a one-task include file, and
# the directory both are resolved from (a playbook's own dir is its role
# search path).
private def write_include_fixtures(prefix : String) : String
  dir = File.tempname(prefix)
  Dir.mkdir_p(File.join(dir, "roles", "r1", "tasks"))
  File.write(File.join(dir, "roles", "r1", "tasks", "main.yml"), <<-YAML)
    - name: role task
      ansible.builtin.debug:
        msg: ROLE-TASK-RAN
    YAML
  File.write(File.join(dir, "included.yml"), <<-YAML)
    - name: included task
      ansible.builtin.debug:
        msg: INCLUDED-TASK-RAN
    YAML
  dir
end
