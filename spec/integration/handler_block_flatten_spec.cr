require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks (a real notified
# handler nested inside a block:, not --check mode), since this is
# about TaskExecutor#flatten_handler_blocks - a private method not
# reachable from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("handler-block", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Real found via robertdebock.rsyslog's own handlers/main.yml, which
# wraps its actual handler in a block: purely to add rescue-time
# diagnostics (see KNOWN_MISSING.md's own writeup for the full verified-
# against-real-ansible-core semantics this spec covers).
describe "a handler nested inside a block:" do
  it "resolves notify: on the inner task's own name instead of aborting with HandlerNotFoundError" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: Restart rsyslog
        handlers:
          - name: Restart rsyslog block
            block:
              - name: Restart rsyslog
                ansible.builtin.debug:
                  msg: RESTART-RAN
      YAML

    status.success?.should be_true
    output.should contain("RESTART-RAN")
    output.should_not contain("HandlerNotFoundError")
  end

  it "does not treat the enclosing block's own name as a valid notify target" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: Restart rsyslog block
        handlers:
          - name: Restart rsyslog block
            block:
              - name: Restart rsyslog
                ansible.builtin.debug:
                  msg: SHOULD-NOT-RUN
      YAML

    status.success?.should be_false
    output.should contain("was not found")
  end

  it "inherits a block-level when: onto the flattened child" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: Restart rsyslog
        handlers:
          - name: Restart rsyslog block
            when: false
            block:
              - name: Restart rsyslog
                ansible.builtin.debug:
                  msg: SHOULD-NOT-RUN
      YAML

    status.success?.should be_true
    output.should_not contain("SHOULD-NOT-RUN")
  end

  # Verified against real ansible-core 2.19.4/2.21.3: notifying a
  # flattened block member runs ONLY that task - the block's rescue:
  # is completely inert for handler purposes, not merely deferred. A
  # failure in the notified task fails the run outright (rescued=0),
  # exactly as if it had never been wrapped in a block at all.
  it "does not run the block's rescue: when the notified task fails" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: Restart rsyslog
        handlers:
          - name: Restart rsyslog block
            block:
              - name: Restart rsyslog
                ansible.builtin.fail:
                  msg: RESTART-FAILED
            rescue:
              - name: rescue step
                ansible.builtin.debug:
                  msg: RESCUE-SHOULD-NOT-RUN
      YAML

    status.success?.should be_false
    output.should_not contain("RESCUE-SHOULD-NOT-RUN")
    output.should contain("rescued=0")
  end

  # rescue:/always: members are not flattened at all - a task
  # notifying one of THEIR names directly must still fail, matching
  # real Ansible exactly (verified live: notifying a rescue: task's own
  # name raises "handler not found" too).
  it "does not make a rescue: task independently notify-able" do
    status, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: rescue step
        handlers:
          - name: Restart rsyslog block
            block:
              - name: Restart rsyslog
                ansible.builtin.debug:
                  msg: irrelevant
            rescue:
              - name: rescue step
                ansible.builtin.debug:
                  msg: irrelevant
      YAML

    status.success?.should be_false
  end
end
