require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Issue #1465: ansible post-validates the any_errors_fatal: keyword with its
# strict boolean() when each task runs, so a value it cannot convert fails
# that task with "Error processing keyword 'any_errors_fatal'" instead of
# running it. The keyword is inherited from the play (by handlers too), so a
# play-level value fails every task that is not skipped, with the chain's
# lower links Origin'd at the play's own value token.
describe "any_errors_fatal: keyword post-validation" do
  it "fails the first task on an unconvertible play-level any_errors_fatal: value" do
    playbook = File.tempname("any-errors-fatal-play-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        any_errors_fatal: kpg-maybe
        tasks:
          - name: Invalid play any_errors_fatal keyword
            ansible.builtin.debug:
              msg: INVALID-ANY-ERRORS-FATAL-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    # The failing task's own Origin, then the play's value token for both
    # lower chain links.
    output_text.must_include("Origin: #{File.expand_path(playbook)}:6:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:21")
    output_text.must_match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails the first task that is not skipped" do
    playbook = File.tempname("any-errors-fatal-skip", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        any_errors_fatal: kpg-maybe
        tasks:
          - name: Skipped
            ansible.builtin.debug:
              msg: SKIPPED-RAN
            when: false
          - name: Invalid play any_errors_fatal keyword
            ansible.builtin.debug:
              msg: INVALID-ANY-ERRORS-FATAL-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.must_include("skipping: [localhost]")
    output_text.includes?("Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:10:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:21")
    output_text.must_match(/failed=1\b/)
    output_text.must_match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a task with its own unconvertible any_errors_fatal: value" do
    playbook = File.tempname("any-errors-fatal-task-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Invalid task any_errors_fatal keyword
            ansible.builtin.debug:
              msg: INVALID-ANY-ERRORS-FATAL-RAN
            any_errors_fatal: kpg-maybe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:5:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:8:25")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a handler that inherits the play's unconvertible value" do
    playbook = File.tempname("any-errors-fatal-handler", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        any_errors_fatal: kpg-maybe
        tasks:
          - name: Notifier
            ansible.builtin.command:
              cmd: /bin/true
            changed_when: true
            any_errors_fatal: false
            notify: Handler with inherited value
          - name: Flush
            ansible.builtin.meta: flush_handlers
        handlers:
          - name: Handler with inherited value
            ansible.builtin.command:
              cmd: /bin/true
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    # The notifier's own any_errors_fatal: false keeps it runnable, so the
    # handler is reached - and fails with the play's value.
    status.success?.must_equal(true, output_text)
    output_text.must_include("RUNNING HANDLER [Handler with inherited value]")
    output_text.includes?("Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.must_include("Origin: #{File.expand_path(playbook)}:15:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:21")
    output_text.must_include("...ignoring")
    output_text.must_match(/ignored=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails an imported role's first task on an unconvertible inherited value" do
    dir = File.tempname("any-errors-fatal-import-role")
    Dir.mkdir_p(File.join(dir, "roles", "r1", "tasks"))
    File.write(File.join(dir, "roles", "r1", "tasks", "main.yml"), <<-YAML)
      - name: role task
        ansible.builtin.debug:
          msg: ROLE-TASK-RAN
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        any_errors_fatal: kpg-maybe
        tasks:
          - name: Static import
            ansible.builtin.import_role:
              name: r1
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    # A role's tasks are loaded at run time, so the play-level value must
    # reach them through the import statement (real inherits it along the
    # parent chain).
    status.success?.must_equal(false, output_text)
    output_text.must_include("TASK [r1 : role task]")
    output_text.includes?("Error processing keyword 'any_errors_fatal': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include(%("msg": "ROLE-TASK-RAN"))
    # The role's own file holds no such keyword: both lower links point at
    # the play's value token.
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:21")
    output_text.must_match(/failed=1\b/)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
