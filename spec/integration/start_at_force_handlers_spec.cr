require "../spec_helper"

# --start-at-task and --force-handlers, both checked against a real
# ansible-core 2.19.4 run of the same playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_with(args : Array(String), yaml : String)
  playbook = File.tempname("start-at", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: stdout_io, error: stdout_io)
  {status, stdout_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def markers(output : String) : Array(String)
  output.scan(/^\s{2}([A-Z0-9-]+)$/m).map { |mat| mat[1] }
end

private TWO_PLAYS = <<-YAML
  - name: Play one
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: task one
        ansible.builtin.debug: {msg: "T1"}
      - name: task two
        ansible.builtin.debug: {msg: "T2"}
      - name: task three
        ansible.builtin.debug: {msg: "T3"}
  - name: Play two
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: task four
        ansible.builtin.debug: {msg: "T4"}
  YAML

private NOTIFY_THEN_FAIL = <<-YAML
  - name: FH
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: notifier
        ansible.builtin.debug: {msg: "N"}
        changed_when: true
        notify: the handler
      - name: boom
        ansible.builtin.command: /bin/false
    handlers:
      - name: the handler
        ansible.builtin.debug: {msg: "HANDLER-RAN"}
  YAML

describe "--start-at-task" do
  it "skips everything before the named task, without counting it" do
    status, output = run_with(["--start-at-task", "task two"], TWO_PLAYS)
    status.exit_code.should eq(0)
    markers(output).should eq(["T2", "T3", "T4"])
    output.should contain("ok=3")
  end

  # The match is playbook-wide: a hit in a later play empties the ones
  # before it entirely.
  it "matches across plays" do
    _, output = run_with(["--start-at-task", "task four"], TWO_PLAYS)
    markers(output).should eq(["T4"])
  end

  # Real Ansible flattens the play, so starting inside a block runs the
  # remainder of that block and everything after it.
  it "can start at a task nested inside a block" do
    yaml = <<-YAML
      - name: B
        hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: before
            ansible.builtin.debug: {msg: "BEFORE"}
          - name: blk
            block:
              - name: inner one
                ansible.builtin.debug: {msg: "I1"}
              - name: inner two
                ansible.builtin.debug: {msg: "I2"}
          - name: after
            ansible.builtin.debug: {msg: "AFTER"}
      YAML

    _, output = run_with(["--start-at-task", "inner two"], yaml)
    markers(output).should eq(["I2", "AFTER"])
  end

  # A name matching nothing runs nothing and still exits 0 - real
  # Ansible treats it as "nothing to do", not an error.
  it "reports a name that matches nothing and exits 0" do
    status, output = run_with(["--start-at-task", "nonexistent"], TWO_PLAYS)
    status.exit_code.should eq(0)
    markers(output).empty?.should be_true
    output.should contain(%([ERROR]: No matching task "nonexistent" found.))
    output.should_not contain("✓ Playbook execution complete")
  end
end

describe "--force-handlers" do
  it "drops a notified handler after a failure by default" do
    status, output = run_with(Array(String).new, NOTIFY_THEN_FAIL)
    status.exit_code.should eq(2)
    output.should_not contain("HANDLER-RAN")
    output.should contain("ok=1")
    output.should contain("failed=1")
  end

  it "runs the handler anyway when asked, without changing failed/rc" do
    status, output = run_with(["--force-handlers"], NOTIFY_THEN_FAIL)
    status.exit_code.should eq(2)
    output.should contain("HANDLER-RAN")
    output.should contain("ok=2")
    output.should contain("failed=1")
  end

  # The play-level keyword does the same thing as the CLI flag.
  it "honors the force_handlers: play keyword" do
    yaml = <<-YAML
      - name: FH
        hosts: localhost
        connection: local
        gather_facts: false
        force_handlers: true
        tasks:
          - name: notifier
            ansible.builtin.debug: {msg: "N"}
            changed_when: true
            notify: the handler
          - name: boom
            ansible.builtin.command: /bin/false
        handlers:
          - name: the handler
            ansible.builtin.debug: {msg: "HANDLER-RAN"}
      YAML

    status, output = run_with(Array(String).new, yaml)
    status.exit_code.should eq(2)
    output.should contain("HANDLER-RAN")
    output.should contain("ok=2")
  end
end
