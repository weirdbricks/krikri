require "../minitest_helper"

# Runs the compiled binary against real playbooks (a real notified
# handler, not --check mode), since this bug lives in the strategy-level
# decision about which task results ever reach the notify: processing
# step - not in anything a unit spec against a single method can
# exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("notify-unfailed-result", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "notify: on a task whose result ansible books as failed" do
  it "does not fire the handler from a loop whose other items changed" do
    # ansible only reads a task's notify: in the strategy branch that
    # handles results which are none of failed/unreachable/skipped, so a
    # loop with a failed item never notifies - even though ignore_errors:
    # lets the play continue and another item reported changed. Live
    # ansible-playbook 2.21.6 runs the handler for an all-ok loop and
    # for none of the mixed fail/change ones; krikri used to notify on
    # any changed item, adding an extra handler to the recap (found by
    # krikri-playbook-generator's 000025-multi-expect-happy).
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: mixed loop
            ansible.builtin.command: '{{ item }}'
            loop:
              - /nonexistent-krikri-953
              - /bin/true
            ignore_errors: true
            notify: mixed handler
        handlers:
          - name: mixed handler
            ansible.builtin.debug:
              msg: mixed handler ran
      YAML

    status.success?.must_equal(true)
    output.must_include("...ignoring")
    output.wont_include("RUNNING HANDLER")
    output.wont_include("mixed handler ran")
  end

  it "does not fire the handler from a non-looped changed-but-failed task" do
    # Same rule for a single result: failed_when: true with
    # changed_when: true under ignore_errors: is still booked failed, so
    # real ansible skips its notify: entirely.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: changed but failed
            ansible.builtin.command: /bin/true
            changed_when: true
            failed_when: true
            ignore_errors: true
            notify: single handler
        handlers:
          - name: single handler
            ansible.builtin.debug:
              msg: single handler ran
      YAML

    status.success?.must_equal(true)
    output.must_include("...ignoring")
    output.wont_include("RUNNING HANDLER")
    output.wont_include("single handler ran")
  end

  it "still fires the handler from an all-changing loop" do
    # The guard must not swallow the ordinary case ansible does notify
    # for: every item changed and none failed.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: all ok loop
            ansible.builtin.command: /bin/true
            loop:
              - one
              - two
            notify: ok handler
        handlers:
          - name: ok handler
            ansible.builtin.debug:
              msg: ok handler ran
      YAML

    status.success?.must_equal(true)
    output.must_include("RUNNING HANDLER [ok handler]")
    output.must_include("ok handler ran")
  end
end
