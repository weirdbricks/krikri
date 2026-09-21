require "../spec_helper"
require "file_utils"

# Real-Ansible check-mode semantics for command/shell (live-verified
# against ansible-core 2.19.11, both modules identically):
#
# - with NO creates:/removes: gate, check mode reports "skipping:"
#   (skipped=1 in the recap) with a full command-module result shape
#   carrying "Command would have run if not in check mode";
# - WITH a gate, the module runs its own gate logic even in check mode
#   and returns an ORDINARY "ok" (changed: false, ok=1): the
#   would-have-run shape when the gate would have let the command
#   through, or the "Would not run command since ..." shape (note the
#   check-mode wording - the ordinary run says "Did not run command
#   since ...") when the gate would have held it back.
#
# The gate-vs-skip split used to be missing entirely: every check-mode
# invocation reported "skipping:", which shifted both engines' recap
# counters on the same playbook (real ok=4/skipped=3 vs this engine
# ok=3/skipped=4) and misreported a gated task's verdict.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

def run_check_mode_playbook(tasks : String, check : Bool) : {Process::Status, String}
  playbook = File.tempname("cmd-check-mode", ".yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n" + tasks)

  args = ["-i", INVENTORY, playbook]
  args << "--check" if check
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "command/shell check-mode gating (creates:/removes:)" do
  it "reports skipping: for a plain shell task under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: plain
            ansible.builtin.shell: echo plain-check-probe
    YAML

    status.success?.should be_true
    output.should contain("skipping:")
    output.should match(/skipped=1\b/)
    output.should_not contain("plain-check-probe")
  end

  it "reports ok: (not skipping:) for a gated shell whose creates: file is missing under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated would run
            ansible.builtin.shell: echo gated-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
    YAML

    status.success?.should be_true
    output.should contain("Command would have run if not in check mode")
    output.should_not contain("skipping:")
    output.should match(/ok=1\b/)
    output.should match(/skipped=0\b/)
  end

  it "uses the Would not run wording when the creates: gate holds under --check" do
    marker = File.tempname("cmd-check-marker")
    File.write(marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated held
            ansible.builtin.shell: echo held-check-probe
            args:
              creates: #{marker}
    YAML

    status.success?.should be_true
    output.should contain("Would not run command since '#{marker}' exists")
    output.should_not contain("skipping:")
    output.should_not contain("held-check-probe")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "uses the Would not run wording for a removes: gate that holds under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: removes held
            ansible.builtin.shell: echo removes-check-probe
            args:
              removes: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
    YAML

    status.success?.should be_true
    output.should_not contain("skipping:")
    output.should match(/Would not run command since '.*' does not exist/)
  end

  it "keeps the Did not run wording for a creates: skip on an ordinary run" do
    marker = File.tempname("cmd-normal-marker")
    File.write(marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: false)
          - name: ordinary skip
            ansible.builtin.shell: echo normal-skip-probe
            args:
              creates: #{marker}
    YAML

    status.success?.should be_true
    output.should contain("Did not run command since '#{marker}' exists")
    output.should_not contain("Would not run command since")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
