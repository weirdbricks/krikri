require "../minitest_helper"
require "file_utils"

# Task-level `check_mode:`. Ansible honours it in both directions
# (verified against ansible-core 2.19.4): `check_mode: true` simulates a
# task during an ordinary run, and `check_mode: false` lets a task
# really run during a `--check` run. Both were ignored here - only the
# global `--check` flag reached the plugins - so a task the playbook
# wanted simulated was really executed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, args : Array(String) = [] of String)
  playbook = File.tempname("task-check-mode", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook] + args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "task-level check_mode:" do
  it "simulates a task during an ordinary run" do
    dest = PluginSpecHelper.tmp_path("simulated.txt")
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: simulated
            ansible.builtin.copy:
              content: "should not be written"
              dest: "#{dest}"
            check_mode: true
      YAML

    status.exit_code.must_equal(0)
    output.must_include("changed")
    File.exists?(dest).must_equal(false)
  end

  # The direction that matters most in practice: a read-only task that
  # has to really run so the rest of a --check play has something to
  # simulate against.
  it "really runs a check_mode: false task during a --check run" do
    dest = PluginSpecHelper.tmp_path("forced.txt")
    status, _ = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: forced
            ansible.builtin.copy:
              content: "written for real"
              dest: "#{dest}"
            check_mode: false
      YAML

    status.exit_code.must_equal(0)
    File.exists?(dest).must_equal(true)
    File.read(dest).must_equal("written for real")
  end

  it "leaves the rest of a --check run simulated" do
    dest = PluginSpecHelper.tmp_path("still-simulated.txt")
    status, _ = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: ordinary
            ansible.builtin.copy:
              content: "should not be written"
              dest: "#{dest}"
      YAML

    status.exit_code.must_equal(0)
    File.exists?(dest).must_equal(false)
  end

  it "evaluates a templated check_mode: against live vars" do
    simulated = PluginSpecHelper.tmp_path("templated-on.txt")
    real = PluginSpecHelper.tmp_path("templated-off.txt")
    status, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          simulate: true
        tasks:
          - name: templated on
            ansible.builtin.copy:
              content: "x"
              dest: "#{simulated}"
            check_mode: "{{ simulate }}"
          - name: templated off
            ansible.builtin.copy:
              content: "x"
              dest: "#{real}"
            check_mode: "{{ not simulate }}"
      YAML

    status.exit_code.must_equal(0)
    File.exists?(simulated).must_equal(false)
    File.exists?(real).must_equal(true)
  end

  # Live-verified against Ansible: the magic var tracks the RUN's
  # mode, not the task's - a check_mode: true task inside an ordinary
  # run still sees ansible_check_mode == false.
  it "does not let a task's check_mode leak into the ansible_check_mode magic var" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: report
            ansible.builtin.debug:
              msg: "MAGIC=[{{ ansible_check_mode }}]"
            check_mode: true
      YAML

    status.exit_code.must_equal(0)
    # Rendered as Python's "False", matching Ansible's own output.
    output.must_include("MAGIC=[False]")
  end

  # Ansible only skips a task before argument validation when the module
  # ships an action plugin declaring _supports_check_mode = False (uri).
  # A module dispatched through the plain `normal` action - tempfile,
  # wait_for and community.mysql's - really runs its AnsibleModule init
  # under --check, which validates the argument spec FIRST and only then
  # hits basic.py's supports_check_mode exit_json gate: so a typo'd
  # option still fails the task under --check (live-verified against
  # 2.21.6). krikri skipped those tasks outright, which also broke any
  # later `is not skipped` gate on the registered result.
  it "fails a typo'd option on a no-check-mode module under --check" do
    status, output = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: tempfile with a typo'd option
            ansible.builtin.tempfile:
              prefix: tmp_
              prefix_bogus: tmp_
            register: tf
            ignore_errors: true
          - name: follow-up gated on the failed task
            ansible.builtin.debug:
              msg: follow-up-ran
            when: tf is not skipped
      YAML

    status.exit_code.must_equal(0)
    output.must_include(%("msg": "Unsupported parameters for (ansible.builtin.tempfile) module: prefix_bogus. Supported parameters include: path, prefix, state, suffix."))
    output.wont_include("does not support check mode")
    output.must_include("follow-up-ran")
  end

  # The action-plugin skip uri does have is still honoured: Ansible never
  # validates uri's module arguments under --check, whatever they are.
  it "skips uri under --check without validating its arguments" do
    status, output = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: uri with a typo'd option
            ansible.builtin.uri:
              url: http://127.0.0.1:1/
              bogus_param: 1
            register: resp
            ignore_errors: true
          - name: report
            ansible.builtin.debug:
              msg: "URI_SKIPPED=[{{ resp.skipped | default(false) }}]"
      YAML

    status.exit_code.must_equal(0)
    output.wont_include("Unsupported parameters")
    output.must_include("URI_SKIPPED=[True]")
  end
end
