require "../minitest_helper"
require "file_utils"

# Real-Ansible check-mode semantics for command/shell (live-verified
# against ansible-core 2.19.11, both modules identically):
#
# - with NO creates:/removes: gate, check mode reports "skipping:"
#   (skipped=1 in the recap) with a full command-module result shape
#   carrying "Command would have run if not in check mode";
# - WITH a gate, the module runs its own gate logic even in check mode.
#   command.py sets r['changed'] = True BEFORE the check-mode branch and
#   that branch only downgrades to skipped/changed=false when BOTH
#   creates and removes are None - so the gated would-run result is
#   CHANGED ("changed:", recap changed=1, handlers notified on the task
#   fire), not an "ok" (issue #1071), and the "Would not run command
#   since ..." shape (note the check-mode wording - the ordinary run
#   says "Did not run command since ...") applies when the gate would
#   have held it back.
#
# The gate-vs-skip split used to be missing entirely: every check-mode
# invocation reported "skipping:", which shifted both engines' recap
# counters on the same playbook (real ok=4/skipped=3 vs this engine
# ok=3/skipped=4) and misreported a gated task's verdict.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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

    status.success?.must_equal(true)
    output.must_include("skipping:")
    output.must_match(/skipped=1\b/)
    output.wont_include("plain-check-probe")
  end

  it "reports changed: for a gated shell whose creates: file is missing under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated would run
            ansible.builtin.shell: echo gated-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
            register: probe
          - debug:
              var: probe
      YAML

    status.success?.must_equal(true)
    output.must_include("Command would have run if not in check mode")
    output.must_include("changed: [localhost]")
    output.wont_include("skipping:")
    output.must_match(/ok=2\b/)
    output.must_match(/changed=1\b/)
    output.must_match(/skipped=0\b/)
  end

  it "fires handlers notified on a gated shell would-run under --check" do
    # issue #1071: the changed verdict is what arms notify in check
    # mode - real ran the handler, this engine didn't while it reported
    # the would-run as unchanged.
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated would run
            ansible.builtin.shell: echo handler-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
            notify: check mode handler
        handlers:
          - name: check mode handler
            debug:
              msg: handler fired
      YAML

    status.success?.must_equal(true)
    output.must_include("RUNNING HANDLER")
    output.must_include("handler fired")
    output.must_match(/changed=1\b/)
  end

  it "reports changed: for a gated command would-run under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated command would run
            ansible.builtin.command: echo gated-command-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
            register: probe
          - debug:
              var: probe
      YAML

    status.success?.must_equal(true)
    output.must_include("Command would have run if not in check mode")
    output.must_include("changed: [localhost]")
    output.wont_include("skipping:")
    output.must_match(/changed=1\b/)
  end

  it "uses the Would not run wording when the creates: gate holds under --check" do
    marker = File.tempname("cmd-check-marker")
    File.write(marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated held
            ansible.builtin.shell: echo held-check-probe
            args:
              creates: #{marker}
            register: probe
          - debug:
              var: probe
      YAML

    status.success?.must_equal(true)
    output.must_include("Would not run command since '#{marker}' exists")
    output.wont_include("skipping:")
    output.wont_include("\"stdout\": \"held-check-probe")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "uses the Would not run wording for a removes: gate that holds under --check" do
    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: removes held
            ansible.builtin.shell: echo removes-check-probe
            args:
              removes: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
            register: probe
          - debug:
              var: probe
      YAML

    status.success?.must_equal(true)
    output.wont_include("skipping:")
    output.must_match(/Would not run command since '.*' does not exist/)
  end

  it "keeps the Did not run wording for a creates: skip on an ordinary run" do
    marker = File.tempname("cmd-normal-marker")
    File.write(marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: false)
          - name: ordinary skip
            ansible.builtin.shell: echo normal-skip-probe
            args:
              creates: #{marker}
            register: probe
          - debug:
              var: probe
      YAML

    status.success?.must_equal(true)
    output.must_include("Did not run command since '#{marker}' exists")
    output.wont_include("Would not run command since")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
