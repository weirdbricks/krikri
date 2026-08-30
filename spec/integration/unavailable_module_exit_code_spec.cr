require "../spec_helper"

# A module with no plugin binary behind it is deliberately SKIPPED
# rather than aborting the run - KNOWN_MISSING.md's role-private-custom-
# modules scope cut, so a role leaning on its own library/*.py stays
# benchmarkable for everything else it does. But the run still ended
# "Playbook execution complete" with exit 0, which is a green light to CI
# for a playbook real ansible-playbook refuses outright ("couldn't
# resolve module/action", rc=4). Verified against a real local
# ansible-core 2.19.4.
#
# The skip behavior itself is unchanged on purpose; only the exit status
# a caller sees now matches.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("unavailable-module", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout_io, error: stdout_io)
  {status, stdout_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unavailable module exit code" do
  it "exits 4 instead of 0 when a task uses a module with no plugin" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uses a module that does not exist
            nonexistent_module_xyz: {}
      YAML

    status.exit_code.should eq(4)
    output.should contain("nonexistent_module_xyz")
    output.should_not contain("✓ Playbook execution complete")
  end

  # The scope cut is preserved: the rest of the play still RUNS, so a
  # role using its own library/*.py remains benchmarkable.
  it "still runs the other tasks rather than aborting the play" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uses a module that does not exist
            nonexistent_module_xyz: {}
          - name: later task
            ansible.builtin.debug:
              msg: "LATER-TASK-RAN"
      YAML

    status.exit_code.should eq(4)
    output.should contain("LATER-TASK-RAN")
  end

  # An unavailable module outranks a failed host (real Ansible would have
  # refused at parse time, before any task could fail).
  it "takes precedence over a failed task's exit code 2" do
    status, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uses a module that does not exist
            nonexistent_module_xyz: {}
          - name: boom
            ansible.builtin.command: /bin/false
      YAML

    status.exit_code.should eq(4)
  end

  # Real Ansible only ever attempts module resolution for a task it's
  # about to run - a task whose own when: is false never contributes to
  # the exit code, even though the module name is still present
  # somewhere in the playbook text. Previously this was a static
  # whole-playbook scan (PlaybookParser.unavailable_modules) that
  # flagged ANY unresolvable module name regardless of reachability -
  # found via buluma.jenkins's own zypper_repository task (round 180),
  # gated behind an OS-family branch that's false on every host this
  # project benchmarks against (Ubuntu/RHEL-family), yet still forcing
  # exit 4 where real Ansible exits 0/2 based on what actually ran.
  it "does not count a module whose task's when: is false" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uses a module that does not exist, but never runs here
            nonexistent_module_xyz: {}
            when: false
          - name: later task
            ansible.builtin.debug:
              msg: "LATER-TASK-RAN"
      YAML

    status.exit_code.should eq(0)
    output.should contain("LATER-TASK-RAN")
    output.should contain("✓ Playbook execution complete")
  end

  # The counterpart: no when: at all (or a true one) still counts,
  # exactly as before - only the false-when: case changed.
  it "still counts a module whose task has no when: at all" do
    status, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uses a module that does not exist
            nonexistent_module_xyz: {}
          - name: uses a module that does not exist, and always runs
            other_nonexistent_module_xyz: {}
            when: true
      YAML

    status.exit_code.should eq(4)
  end

  # Guard against over-reach: a playbook using only real modules must
  # still exit 0.
  it "does not affect a playbook whose modules all exist" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fine
            ansible.builtin.debug:
              msg: "fine"
      YAML

    status.exit_code.should eq(0)
    output.should contain("✓ Playbook execution complete")
  end
end
