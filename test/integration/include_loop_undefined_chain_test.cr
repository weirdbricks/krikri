require "../minitest_helper"

# Issue #62 - an undefined loop-source variable on a looped include_tasks:
# (`loop: "{{ ssls }}"` / `with_items: "{{ ssls }}"`, exphost.ssl_generator
# and melvin_suter.web_stack_deployment) must print the same [ERROR] chain
# block ("Task failed." + the task Origin, "<<< caused by >>>" with the
# inner variable's Origin pinned at the loop VALUE token) and the prefixed
# {"changed": false, "msg": "Task failed: ..."} fatal that the ordinary
# task path's loop-source resolution already produces - the old
# swallow_when_error path here printed a bare `fatal: ... => 'ssls' is
# undefined` with no chain block and no prefix. Verified live against
# ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("include-loop-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "looped include_tasks with an undefined loop source" do
  it "prints the Task failed chain block and prefixed fatal for loop:" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            loop: "{{ ssls }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: 'ssls' is undefined")
    output.must_include("Task failed.")
    output.must_include("<<< caused by >>>")
    # The cause block pins the Origin at the loop VALUE token, not the
    # task keyword.
    output.must_include("loop: \"{{ ssls }}\"")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'ssls' is undefined\"}")
    output.must_include("failed=1")
    output.wont_include("FAILED! => 'ssls' is undefined")
  end

  it "prints the same shape for with_items:" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include_tasks
            ansible.builtin.include_tasks: "no_such_file.yml"
            with_items: "{{ ssls }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: 'ssls' is undefined")
    output.must_include("<<< caused by >>>")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'ssls' is undefined\"}")
    output.must_include("failed=1")
  end
end
