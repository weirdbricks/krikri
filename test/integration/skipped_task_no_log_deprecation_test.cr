require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (real localhost
# connection) since the bug is about which deprecation warnings the
# executor emits for a task that is SKIPPED by when:. Ansible templates
# the task's no_log keyword even for a when:-skipped task, so the bool
# filter's invalid-value deprecation is printed before the skipping
# line (issue #671) - krikri previously printed nothing there.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("skipped-no-log-deprecation", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "when:-skipped task still templates no_log (deprecation side effect)" do
  it "prints the bool filter's invalid-value deprecation before the skipping line for a task with when: false" do
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: skipped but no_log still templated
            ansible.builtin.debug:
              msg: "hello"
            no_log: "{{ not lookup('env', 'KRIKRI_ISSUE_671_UNSET') | bool }}"
            when: false
      YAML

    status.success?.must_equal(true)
    output.must_include("[DEPRECATION WARNING]: The `bool` filter coerced invalid value '' (str) to False.")
    output.must_include("skipping: [localhost]")
  end

  it "prints the same deprecation for a block child whose block is skipped by when: false (the zhan9san.postgres_exporter shape)" do
    # The role's own shape: a block: with when: false whose child task
    # carries the templated no_log. The block-level skip never reaches
    # when_passes?, so the child's no_log must be evaluated by the block
    # skip printer itself.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - block:
              - name: block child with templated no_log
                ansible.builtin.debug:
                  msg: "hello"
                no_log: "{{ not lookup('env', 'KRIKRI_ISSUE_671_UNSET') | bool }}"
            when: false
      YAML

    status.success?.must_equal(true)
    output.must_include("[DEPRECATION WARNING]: The `bool` filter coerced invalid value '' (str) to False.")
    output.must_include("skipping: [localhost]")
  end
end
