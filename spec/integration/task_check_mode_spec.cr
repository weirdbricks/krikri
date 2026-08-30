require "../spec_helper"
require "file_utils"

# Task-level `check_mode:`. Real Ansible honours it in both directions
# (verified against ansible-core 2.19.4): `check_mode: true` simulates a
# task during an ordinary run, and `check_mode: false` lets a task
# really run during a `--check` run. Both were ignored here - only the
# global `--check` flag reached the plugins - so a task the playbook
# wanted simulated was really executed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")
private TMP_DIR      = File.join(PROJECT_ROOT, "spec", "tmp", "task_check_mode")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

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
    dest = File.join(TMP_DIR, "simulated.txt")
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

    status.exit_code.should eq(0)
    output.should contain("changed")
    File.exists?(dest).should be_false
  end

  # The direction that matters most in practice: a read-only task that
  # has to really run so the rest of a --check play has something to
  # simulate against.
  it "really runs a check_mode: false task during a --check run" do
    dest = File.join(TMP_DIR, "forced.txt")
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

    status.exit_code.should eq(0)
    File.exists?(dest).should be_true
    File.read(dest).should eq("written for real")
  end

  it "leaves the rest of a --check run simulated" do
    dest = File.join(TMP_DIR, "still-simulated.txt")
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

    status.exit_code.should eq(0)
    File.exists?(dest).should be_false
  end

  it "evaluates a templated check_mode: against live vars" do
    simulated = File.join(TMP_DIR, "templated-on.txt")
    real = File.join(TMP_DIR, "templated-off.txt")
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

    status.exit_code.should eq(0)
    File.exists?(simulated).should be_false
    File.exists?(real).should be_true
  end

  # Live-verified against real Ansible: the magic var tracks the RUN's
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

    status.exit_code.should eq(0)
    # Rendered as Python's "False", matching real Ansible's own output.
    output.should contain("MAGIC=[False]")
  end
end
