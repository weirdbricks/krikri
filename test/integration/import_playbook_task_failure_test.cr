require "../minitest_helper"
require "file_utils"

# A task-level `import_playbook:` (issue #762). ansible-core ships the
# action as a doc-only stub module (lib/ansible/modules/import_playbook.py
# - DOCUMENTATION and EXAMPLES only, no code, no shebang), so a task whose
# action is one of its spellings RESOLVES on the controller and then dies
# in the base action plugin's _execute_module shebang check: a per-task
# failure "Task failed: module (X) is missing interpreter line" (X = the
# as-written spelling) with the task's own Origin block, honoring
# ignore_errors: and register:. krikri used to fold it into the graceful
# unported-module skip (recap skipped=1, exit-4 "uses unimplemented plugin"
# report) - a divergence on every generator-produced happy-path playbook.
#
# All shapes below were live-captured against ansible-playbook 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("import-playbook-task", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "task-level import_playbook fails like ansible's stub module" do
  it "fails a reached ansible.builtin.import_playbook task with the shebang error, honoring ignore_errors and register" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
        - name: 'import_playbook #0'
          ansible.builtin.import_playbook: {}
          register: r1
          ignore_errors: true
        - name: show
          ansible.builtin.debug:
            msg: "failed={{ r1.failed | default('none') }} changed={{ r1.changed | default('none') }}"
      YAML

    output.must_include("[ERROR]: Task failed: module (ansible.builtin.import_playbook) is missing interpreter line")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: module (ansible.builtin.import_playbook) is missing interpreter line\"}")
    output.must_include("...ignoring")
    # The registered result keeps the failed verdict and the "Task failed: "
    # brief (real's debug: prints failed=True changed=False and the msg).
    output.must_include("failed=True changed=False")
    output.must_include("ignored=1")
    output.wont_include("uses unimplemented plugin")
  end

  it "echoes the as-written bare spelling in the message" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
        - name: bare spelling
          import_playbook: {}
          ignore_errors: true
      YAML

    output.must_include("[ERROR]: Task failed: module (import_playbook) is missing interpreter line")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: module (import_playbook) is missing interpreter line\"}")
  end

  it "points the Origin block at the task's own mapping line" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
        - name: 'import_playbook #0'
          ansible.builtin.import_playbook: {}
          ignore_errors: true
      YAML

    # The task's `- name:` mapping starts on line 4, column 5 - the same
    # position real's Origin pins (live-captured: the enclosing play lines
    # plus the caret under column 5).
    output.must_include("Origin: ")
    output.must_include("4   - name: 'import_playbook #0'")
    output.must_include("^ column 5")
  end

  it "still skips a when:-false import_playbook task like any other" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
        - name: gated
          ansible.builtin.import_playbook: {}
          when: false
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.wont_include("missing interpreter line")
    output.wont_include("uses unimplemented plugin")
  end

  it "fails each reached loop item with the shebang error, not a skip" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
        - name: looped
          ansible.builtin.import_playbook: {}
          loop:
          - a
          - b
          ignore_errors: true
      YAML

    # Real prints the [ERROR] block once (Display dedup) before the two
    # per-item failed lines and `...ignoring` once after the whole loop;
    # the recap counts the ignored TASK once, not per item (live-captured:
    # a two-item loop ignores=1).
    output.lines.count(&.includes?("[ERROR]: Task failed: module (ansible.builtin.import_playbook) is missing interpreter line")).must_equal(1)
    output.must_include("failed: [localhost] (item=a)")
    output.must_include("failed: [localhost] (item=b)")
    output.must_include("ignored=1")
  end

  it "fails a fired import_playbook handler with the shebang error, not a skip" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        gather_facts: false
        handlers:
        - name: imp handler
          ansible.builtin.import_playbook: {}
          ignore_errors: true
          listen: go
        tasks:
        - name: notify it
          ansible.builtin.debug:
          changed_when: true
          notify: go
      YAML

    output.must_include("[ERROR]: Task failed: module (ansible.builtin.import_playbook) is missing interpreter line")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: module (ansible.builtin.import_playbook) is missing interpreter line\"}")
  end
end
