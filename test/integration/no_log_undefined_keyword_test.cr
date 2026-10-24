require "../minitest_helper"
require "file_utils"

# Regression spec for issue #317: a task's templated no_log: whose variable
# is UNDEFINED fails the task outright in ansible-core 2.19, at keyword-
# templating time before the module ever runs ("Task failed: Error
# processing keyword 'no_log': 'debug_hide' is undefined", rc 2). Real
# prints the "Invalid no_log value for task, output will be masked"
# warning and still shows the result censored (no "changed" key in the
# fatal dump - the failure is pre-module). krikri used to render the
# lenient "undefined" sentinel and run the task masked as "ok".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a templated no_log on an undefined variable fails the task like ansible" do
  it "fails the task with the keyword error chain and a censored fatal (no changed key)" do
    root = File.tempname("no-log-undefined")
    Dir.mkdir_p(root)
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: nolog undefined
            no_log: "{{ debug_hide }}"
            debug:
              msg: hi
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: root)

    status.success?.must_equal(false, "#{stdout}\n#{stderr}")
    stdout_text = stdout.to_s
    # ansible-core 2.19's two-level keyword chain before the fatal line:
    # "Task failed." at the task's `- name:` key, the collapsed keyword
    # message at the no_log value token itself (the `"` of the value, the
    # colon is column 13 and the space column 14).
    stdout_text.includes?("[ERROR]: Task failed: Error processing keyword 'no_log': 'debug_hide' is undefined").must_equal(true, stdout_text)
    stdout_text.includes?("Task failed.\nOrigin: #{playbook}:5:7").must_equal(true, stdout_text)
    stdout_text.includes?("<<< caused by >>>").must_equal(true, stdout_text)
    stdout_text.includes?("Error processing keyword 'no_log': 'debug_hide' is undefined").must_equal(true, stdout_text)
    stdout_text.includes?("Origin: #{playbook}:6:15").must_equal(true, stdout_text)
    # The result is still masked, censored-only: no module ran (no
    # "changed" in the dump - a masked module failure would carry one).
    stdout_text.includes?("fatal: [localhost]: FAILED! => {\"censored\": \"the output has been hidden due to the fact that 'no_log: true' was specified for this result\"}").must_equal(true, stdout_text)
    stdout_text.includes?("\"censored\": \"the output has been hidden due to the fact that 'no_log: true' was specified for this result\", \"changed\"").must_equal(false, stdout_text)
    # The task never ran: the keyword fails before any action plugin.
    stdout_text.includes?("msg\": \"hi\"").must_equal(false, stdout_text)
    # The play ends with the failure in the recap.
    stdout_text.includes?("failed=1").must_equal(true, stdout_text)

    # The warning rides stderr with its own cause chain (the collapsed
    # one-liner ansible's Display.warning shows, then the same two records
    # with the no_log value's Origin).
    stderr_text = stderr.to_s
    stderr_text.includes?("[WARNING]: Invalid no_log value for task, output will be masked: Error processing keyword 'no_log': 'debug_hide' is undefined").must_equal(true, stderr_text)
    stderr_text.includes?("Invalid no_log value for task, output will be masked.").must_equal(true, stderr_text)
    stderr_text.includes?("Origin: #{playbook}:6:15").must_equal(true, stderr_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "keeps running a templated no_log on a DEFINED variable" do
    root = File.tempname("no-log-defined")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: nolog defined
            no_log: "{{ hide }}"
            vars:
              hide: "yes"
            debug:
              msg: hi
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: root)

    status.success?.must_equal(true, "#{stdout}\n#{stderr}")
    stdout.to_s.includes?("ok: [localhost]").must_equal(true, stdout.to_s)
    stderr.to_s.includes?("Invalid no_log value").must_equal(false, stderr.to_s)
    stdout.to_s.includes?("is undefined").must_equal(false, stdout.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "keeps `| default(false)` on an absent variable answering no_log: false" do
    # The idiom's dominant real-world form (newrelic.newrelic-infra's
    # no_log:): the tolerant filter consumes the absent name and the task
    # runs unmasked, verbatim like before the strict probe existed.
    root = File.tempname("no-log-default")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: nolog default false
            no_log: "{{ debug_hide | default(false) }}"
            debug:
              msg: hi
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: root)

    status.success?.must_equal(true, "#{stdout}\n#{stderr}")
    stdout_text = stdout.to_s
    stdout_text.includes?("msg\": \"hi\"").must_equal(true, stdout_text)
    stdout_text.includes?("ok: [localhost]").must_equal(true, stdout_text)
    stderr.to_s.includes?("Invalid no_log value").must_equal(false, stderr.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails a notified handler with an undefined templated no_log the same way" do
    root = File.tempname("no-log-undefined-handler")
    Dir.mkdir_p(root)
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.command: "true"
            notify: the handler
        handlers:
          - name: the handler
            no_log: "{{ debug_hide }}"
            debug:
              msg: reloaded
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: root)

    status.success?.must_equal(false, "#{stdout}\n#{stderr}")
    stdout_text = stdout.to_s
    stdout_text.includes?("[ERROR]: Task failed: Error processing keyword 'no_log': 'debug_hide' is undefined").must_equal(true, stdout_text)
    stdout_text.includes?("fatal: [localhost]: FAILED! => {\"censored\": \"the output has been hidden due to the fact that 'no_log: true' was specified for this result\"}").must_equal(true, stdout_text)
    # The handler never ran.
    stdout_text.includes?("msg\": \"reloaded\"").must_equal(false, stdout_text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
