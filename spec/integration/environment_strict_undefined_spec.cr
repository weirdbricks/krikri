require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook - the environment:
# keyword's strict-undefined behavior lives in TaskExecutor#substitute_
# task_environment (private, called from the "finalization of task args"
# block), so only a full run can prove both the failure and the success
# shapes end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "environment: keyword strict-undefined" do
  # ryandaniels.server_update_reboot (round 300094): its apt/yum tasks set
  # `environment: "{{ proxy_env }}"` with proxy_env defined NOWHERE in the
  # role (it comes from the caller's inventory/vars). Real ansible-playbook
  # fails each such task with "Error processing keyword 'environment':
  # 'proxy_env' is undefined"; krikri's parser silently dropped the
  # non-hash form and the executor substituted the (never-parsed) values
  # leniently, so the tasks ran with no env at all.
  it "fails the task when the referenced variable is undefined" do
    playbook = File.tempname("environment-strict-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: apt-like task with undefined proxy_env
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'proxy_env' is undefined")
    output.to_s.should contain("Error processing keyword 'environment'")
    output.to_s.should contain("failed=1")
  end

  it "fails the task for an undefined value inside a dict-form environment" do
    playbook = File.tempname("environment-dict-strict-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: dict-form environment with undefined value
            ansible.builtin.command: /bin/true
            environment:
              MISSING_VAR: "{{ never_defined_anywhere }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'never_defined_anywhere' is undefined")
    output.to_s.should contain("failed=1")
  end

  it "still applies the env vars when the variable IS defined" do
    playbook = File.tempname("environment-defined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          proxy_env:
            KRIKRI_ENV_PROBE: "hello-from-env"
        tasks:
          - name: shell reads the env var
            ansible.builtin.shell: echo "$KRIKRI_ENV_PROBE"
            environment: "{{ proxy_env }}"
            register: probe
          - name: show it
            ansible.builtin.debug:
              var: probe.stdout
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("hello-from-env")
  end
end
