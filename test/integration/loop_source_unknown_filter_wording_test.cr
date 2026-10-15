require "../minitest_helper"

# An unknown filter inside a loop SOURCE (`loop: "{{ lst | no_such_filter }}"`)
# is ansible-core 2.19's template-syntax-error class, not a task-arg failure:
# it prints the bare wording ("Syntax error in template: No filter named 'X'.")
# with NO "Task failed:" prefix and a bodyless [ERROR] block whose Origin is
# pinned at the loop keyword's VALUE token - the same shape a lookup failing
# inside the loop source's own template gets (issue #12), not the "Task
# failed." chain block a module failure gets. Live-compared against
# ansible-playbook 2.19.11 (issue #119).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("loop-unknown-filter", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unknown filter in loop source: Syntax error in template" do
  it "fails a loop: source with an unknown filter, bare msg, loop-value Origin" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          lst: [a, b]
        tasks:
          - ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ lst | no_such_filter }}"
      YAML
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Syntax error in template: No filter named 'no_such_filter'.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Syntax error in template: No filter named 'no_such_filter'.\"}")
    # the Origin points at the loop VALUE token (the quote of the template),
    # not the task's name key - same convention as the LoopTypeError block
    output.must_match(/Origin: .*loop-unknown-filter.*\.yml:9:13/)
    output.must_include("loop: \"{{ lst | no_such_filter }}\"")
    output.wont_include("Task failed:")
    output.wont_include("Provide a list of items/templates")
    output.wont_include("Unhandled exception")
  end
end
