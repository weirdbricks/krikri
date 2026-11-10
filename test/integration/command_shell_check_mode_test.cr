require "../minitest_helper"
require "file_utils"

# Real-Ansible check-mode semantics for command/shell (live-verified
# against ansible-core 2.19.11, both modules identically):
#
# - with NO creates:/removes: gate, check mode reports "skipping:"
#   (skipped=1 in the recap) with a full command-module result shape
#   carrying "Command would have run if not in check mode";
# - WITH a gate, the module runs its own gate logic even in check
#   mode: when the gate would have let the command through, the result
#   is changed: true (recap changed=1, verdict "changed:") carrying the
#   would-have-run shape and NO skipped key at all (real command.py
#   sets changed=True before its check-mode branch and only reverts it
#   when neither gate param exists), and handlers notified on the task
#   fire; the "Would not run command since ..." shapes (note the
#   check-mode wording - the ordinary run says "Did not run command
#   since ...") when the gate would have held it back stay
#   changed: false.
#
# The gate-vs-skip split used to be missing entirely: every check-mode
# invocation reported "skipping:", which shifted both engines' recap
# counters on the same playbook (real ok=4/skipped=3 vs this engine
# ok=3/skipped=4) and misreported a gated task's verdict. The gated
# would-run case then also reported ok/changed: false (spurious
# "skipped": false) where real reports changed: true - live-verified
# against real ansible-playbook --check on this host (issue #1070).
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

  it "reports changed: (not ok:) for a gated shell whose creates: file is missing under --check" do
    removes_marker = File.tempname("gated-removes-probe")
    File.write(removes_marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated would run
            ansible.builtin.shell: echo gated-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
              removes: #{removes_marker}
            register: probe
          - debug:
              msg: "{{ probe.changed }} {{ probe.skipped | default('no-skipped-key') }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("changed: [localhost]")
    output.wont_include("skipping:")
    output.must_include("True no-skipped-key")
    output.must_match(/changed=1\b/)
    output.must_match(/skipped=0\b/)
  ensure
    File.delete(removes_marker) if removes_marker && File.exists?(removes_marker)
  end

  it "reports the same changed: true would-run shape for a gated command under --check" do
    removes_marker = File.tempname("gated-removes-probe")
    File.write(removes_marker, "x")

    status, output = run_check_mode_playbook(<<-YAML, check: true)
          - name: gated would run
            ansible.builtin.command: echo gated-check-probe
            args:
              creates: #{__DIR__}/definitely-missing-#{Random::Secure.hex(4)}.txt
              removes: #{removes_marker}
      YAML

    status.success?.must_equal(true)
    output.must_include("changed: [localhost]")
    output.wont_include("skipping:")
    output.must_match(/changed=1\b/)
  ensure
    File.delete(removes_marker) if removes_marker && File.exists?(removes_marker)
  end

  it "fires handlers notified on a gated shell would-run under --check" do
    # The changed verdict is what arms notify in check mode - real ran
    # the handler, this engine didn't while it reported the would-run as
    # unchanged (issue #1071).
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
