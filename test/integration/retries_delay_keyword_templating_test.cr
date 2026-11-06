require "../minitest_helper"
require "file_utils"

# A retries:/delay: keyword that fails its own templating fails the whole
# task BEFORE the module runs (issue #694): real 2.19.11 prints one
# [ERROR] keyword chain + fatal with no attempts key, registers the
# failure, and ignores it under ignore_errors: - it never runs the module
# the old lenient fallback silently executed while substituting the
# implicit 3/5 defaults.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "retries/delay keyword templating failures" do
  it "fails a task whose retries template references an undefined variable" do
    tempdir = File.tempname("retries-undef").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail repeatedly
            ansible.builtin.command:
              cmd: /bin/false
            register: r
            retries: "{{ nope_var }}"
            delay: 0
            until: r is success
            ignore_errors: true
          - name: show r
            ansible.builtin.debug:
              msg: "r={{ r is defined }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # The module never runs: no retry lines, no attempts key, and the
    # registered failure is still visible to the follow-up task.
    text.must_include("[ERROR]: Task failed: Error processing keyword 'retries': 'nope_var' is undefined")
    text.must_include("Error processing keyword 'retries': 'nope_var' is undefined")
    text.wont_include("FAILED - RETRYING")
    text.wont_include("\"attempts\"")
    text.must_include("\"msg\": \"Task failed: Error processing keyword 'retries': 'nope_var' is undefined\"")
    text.must_include("...ignoring")
    text.must_include("msg\": \"r=True")
    text.must_include("ignored=1")
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails a task whose delay template references an undefined variable" do
    tempdir = File.tempname("delay-undef").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail repeatedly
            ansible.builtin.command:
              cmd: /bin/false
            register: r
            retries: 2
            delay: "{{ nope_var }}"
            until: r is success
            ignore_errors: true
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Error processing keyword 'delay': 'nope_var' is undefined")
    text.wont_include("FAILED - RETRYING")
    text.wont_include("\"attempts\"")
    text.must_include("ignored=1")
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails a task whose retries template renders to a non-integer" do
    tempdir = File.tempname("retries-nonint").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail repeatedly
            ansible.builtin.command:
              cmd: /bin/false
            register: r
            retries: "{{ 'abc' }}"
            delay: 0
            until: r is success
            ignore_errors: true
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("The value 'abc' could not be converted to 'int'.")
    text.wont_include("FAILED - RETRYING")
    text.wont_include("\"attempts\"")
    text.must_include("ignored=1")
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "still retries a task whose retries template resolves to an integer" do
    tempdir = File.tempname("retries-templated-ok").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          retries_n: 2
        tasks:
          - name: fail repeatedly
            ansible.builtin.command:
              cmd: /bin/false
            register: r
            retries: "{{ retries_n }}"
            delay: 0
            until: r is success
            ignore_errors: true
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("FAILED - RETRYING: [localhost]: fail repeatedly (1 retries left).")
    text.must_include("FAILED - RETRYING: [localhost]: fail repeatedly (0 retries left).")
    text.must_include("\"attempts\": 2")
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
