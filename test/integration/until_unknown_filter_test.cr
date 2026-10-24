require "../minitest_helper"

# An unknown filter/test name in an `until:` condition (ansible-core 2.19's
# "Syntax error in expression" class - `search` is a TEST, pipelines that
# write `result.stderr | search (...)` compile-fail) is real's one clean
# fatal task failure: Jinja compiles the whole condition as an expression
# the first time it is evaluated, the failure lands at the until: value
# token in the [ERROR] chain, the task fails after the first attempt's run
# (no retrying lines), and the host halts with failed=1. krikri used to let
# the raise escape the attempt loop unhandled - crashing the process at
# top level and, from inside an include_tasks: file, degrading to the
# include loader's misleading "Failed to load included tasks:" failure
# instead (issue #318).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(playbook : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
end

# *indent* shifts every task line so the block sits right either as a
# top-level tasks list (the include file) or inside a play's `tasks:`
# key. Built here instead of interpolated into the play's own dedented
# heredoc - there the inserted lines keep their relative shift against
# the play's and the play parses as a YAML error (rc=4) before either
# engine's behavior is even reached.
private def until_task_yaml(counter : String, indent : String = "") : String
  ["#{indent}- name: The system's identity ID is collected",
   "#{indent}  ansible.builtin.shell: echo attempt >> #{counter}",
   "#{indent}  register: result",
   "#{indent}  retries: 1",
   "#{indent}  delay: 0",
   "#{indent}  until: result is success and (result.stdout | trim | length or result.stderr | search ('x'))"].join("\n")
end

describe "until: with an unknown filter or test name" do
  it "fails the task as a fatal syntax error after the first attempt, retry loop never entered" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    counter = PluginSpecHelper.tmp_path("attempts")
    File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n" + until_task_yaml(counter, "    ") + "\n")

    status, output = run_playbook(playbook)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    # ansible-core compiles the whole condition before it can even be
    # true, so the first attempt HAS run (the shell side-effect landed)
    # when the failure surfaces - and the failure means no retry line
    # ever prints, unlike an until: that merely stays false.
    File.read_lines(counter).size.must_equal(1)
    output.must_include("[ERROR]: Task failed: Syntax error in expression: No filter named 'search'.")
    output.must_include("Syntax error in expression: No filter named 'search'.\nOrigin: ")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Syntax error in expression: No filter named 'search'.\"}")
    output.wont_include("FAILED - RETRYING")
    output.wont_include("Unhandled exception")
    output.must_include("failed=1")
  end

  it "fails the included until: task itself, not a 'Failed to load included tasks' degradation" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(PluginSpecHelper.tmp_path("included.yml"), until_task_yaml("/dev/null"))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks: included.yml
      YAML

    status, output = run_playbook(playbook)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    # The include itself loads fine (the chain Origin points INTO the
    # included file, so the real chain shape survives there too) - the
    # fatal is the until: task's own, real wording, not the include
    # loader's legacy generic rescue turning the raise into a bogus
    # load failure.
    output.must_include("[ERROR]: Task failed: Syntax error in expression: No filter named 'search'.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Syntax error in expression: No filter named 'search'.\"}")
    output.wont_include("Failed to load included tasks")
    output.wont_include("Unhandled exception")
    output.must_include("failed=1")
  end
end
