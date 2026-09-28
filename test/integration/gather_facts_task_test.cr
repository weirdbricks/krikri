require "../minitest_helper"
require "file_utils"

# Task-level `ansible.builtin.gather_facts` - real Ansible lets
# gather_facts be invoked as an ordinary task (an action plugin that
# delegates to setup, accepting the same gather_subset/gather_timeout/
# fact_path/filter params), not just as the play-level `gather_facts:`
# keyword. krikri only implemented the play-level setting, so a direct
# task was skipped and the run exited rc=4 with "Playbook execution
# completed with unavailable modules: ansible.builtin.gather_facts"
# while real ansible-playbook ran ok=1.
#
# Found by krikri-playbook-generator (random 2-module smoke test,
# gather_facts + debconf, seed 42, --run-on-podman).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("gather-facts-task", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "task-level gather_facts" do
  it "runs as an ordinary task on a gather_facts: false play (the original repro)" do
    status, output = run_playbook(<<-YAML)
      - name: gather_facts test
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gather_facts #0
            ansible.builtin.gather_facts: {}
            register: result
            ignore_errors: true
          - name: use the gathered result
            ansible.builtin.debug:
              msg: "hostname={{ result.ansible_facts.ansible_hostname }} nprocessors={{ result.ansible_facts.ansible_processor_nproc | default('MISSING') }}"
            when: result is not skipped
      YAML

    status.success?.must_equal(true, output)
    output.wont_include("unavailable modules", output)
    output.wont_include("skipping: [localhost]", output)
    output.must_include("hostname=", output)
    output.wont_include("hostname=MISSING", output)
  end

  it "merges the gathered facts into the host's vars for later tasks" do
    status, output = run_playbook(<<-YAML)
      - name: gather then use
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gather_facts #0
            ansible.builtin.gather_facts: {}
          - name: read a fact directly
            ansible.builtin.debug:
              msg: "os={{ ansible_distribution | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("os=Linux", output)
    output.wont_include("os=MISSING", output)
  end

  it "respects the task's gather_subset (task-level, not the play keyword)" do
    status, output = run_playbook(<<-YAML)
      - name: gather with subset
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gather_facts #0
            ansible.builtin.gather_facts:
              gather_subset: "!all,min"
            register: result
          - name: show what came back
            ansible.builtin.debug:
              msg: "keys={{ result.ansible_facts | list | count }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("keys=", output)
    output.wont_include("keys=0", output)
  end

  it "respects the task's filter param" do
    status, output = run_playbook(<<-YAML)
      - name: gather filtered
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gather_facts #0
            ansible.builtin.gather_facts:
              filter: "ansible_hostname"
            register: result
          - name: show what came back
            ansible.builtin.debug:
              msg: "h={{ result.ansible_facts.ansible_hostname | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.wont_include("h=MISSING", output)
  end

  it "resolves the bare gather_facts spelling too" do
    status, output = run_playbook(<<-YAML)
      - name: bare spelling
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gather_facts #0
            gather_facts: {}
            register: result
          - name: read it
            ansible.builtin.debug:
              msg: "got={{ result.ansible_facts.ansible_hostname | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.wont_include("unavailable modules", output)
    output.wont_include("got=MISSING", output)
  end
end
