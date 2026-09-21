require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

# Real Ansible honors `check_mode:` at play, block AND task level (2.7+),
# most specific wins; command/shell/raw/script do not support check mode,
# so their execution hinges entirely on the resolved value. This engine
# only ever read the TASK-level key: a play- or block-level
# `check_mode: true` (simulate) let those tasks execute for real on an
# ordinary run, and a play- or block-level `check_mode: false` (force
# real execution under --check) was skipped where real Ansible really
# ran them. Both live-verified against ansible-core 2.19.11.
private def run_playbook(yaml : String, check : Bool) : {Process::Status, String}
  playbook = File.tempname("check-mode-scope", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  args = check ? ["--check", "-i", INVENTORY, playbook] : ["-i", INVENTORY, playbook]
  status = Process.run(BINARY, args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "check_mode scope inheritance (play/block/task)" do
  it "runs a command for real under --check when the BLOCK sets check_mode: false" do
    marker = File.tempname("krikri-cm-block-force")
    File.delete(marker) if File.exists?(marker)
    status, output = run_playbook(<<-YAML, check: true)
      - name: block-level force
        hosts: all
        gather_facts: false
        tasks:
          - name: blk
            block:
              - name: really run
                ansible.builtin.command: touch #{marker}
            check_mode: false
      YAML
    status.success?.should be_true
    output.should_not contain("skipping")
    File.exists?(marker).should be_true
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "simulates a command on an ordinary run when the BLOCK sets check_mode: true" do
    marker = File.tempname("krikri-cm-block-sim")
    File.delete(marker) if File.exists?(marker)
    status, output = run_playbook(<<-YAML, check: false)
      - name: block-level simulate
        hosts: all
        gather_facts: false
        tasks:
          - name: blk
            block:
              - name: simulated only
                ansible.builtin.command: touch #{marker}
            check_mode: true
      YAML
    status.success?.should be_true
    output.should contain("skipping")
    File.exists?(marker).should be_false
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "runs a command for real under --check when the PLAY sets check_mode: false" do
    marker = File.tempname("krikri-cm-play-force")
    File.delete(marker) if File.exists?(marker)
    status, output = run_playbook(<<-YAML, check: true)
      - name: play-level force
        hosts: all
        gather_facts: false
        check_mode: false
        tasks:
          - name: really run
            ansible.builtin.command: touch #{marker}
      YAML
    status.success?.should be_true
    output.should_not contain("skipping")
    File.exists?(marker).should be_true
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "simulates a command on an ordinary run when the PLAY sets check_mode: true" do
    marker = File.tempname("krikri-cm-play-sim")
    File.delete(marker) if File.exists?(marker)
    status, output = run_playbook(<<-YAML, check: false)
      - name: play-level simulate
        hosts: all
        gather_facts: false
        check_mode: true
        tasks:
          - name: simulated only
            ansible.builtin.command: touch #{marker}
      YAML
    status.success?.should be_true
    output.should contain("skipping")
    File.exists?(marker).should be_false
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "lets a task's own check_mode: override the block's" do
    # Real Ansible precedence task > block > play: the block says
    # simulate, the task opts back into real execution.
    marker = File.tempname("krikri-cm-task-over-block")
    File.delete(marker) if File.exists?(marker)
    status, _output = run_playbook(<<-YAML, check: false)
      - name: task overrides block
        hosts: all
        gather_facts: false
        tasks:
          - name: blk
            block:
              - name: really run
                ansible.builtin.command: touch #{marker}
                check_mode: false
            check_mode: true
      YAML
    status.success?.should be_true
    File.exists?(marker).should be_true
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "still simulates a plain command under --check with no explicit check_mode anywhere" do
    marker = File.tempname("krikri-cm-plain-check")
    File.delete(marker) if File.exists?(marker)
    status, output = run_playbook(<<-YAML, check: true)
      - name: plain check mode
        hosts: all
        gather_facts: false
        tasks:
          - name: simulated only
            ansible.builtin.command: touch #{marker}
      YAML
    status.success?.should be_true
    output.should contain("skipping")
    File.exists?(marker).should be_false
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
