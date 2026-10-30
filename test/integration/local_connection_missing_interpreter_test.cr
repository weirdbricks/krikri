require "../minitest_helper"
require "file_utils"

# Issue #374 (2kloc.trellis-monit): a task with a `connection: local`
# override still resolves its python interpreter from the PLAYED HOST's
# vars - the ansible_python_interpreter var, or the interpreter the
# host's own fact gathering discovered (discovered_interpreter_python).
# When that path exists only on the remote host, real's controller-side
# module execution dies with rc 127 and an empty module stdout, which
# the action reports as the module-interpreter-not-found failure:
# "[ERROR]: Task failed: Action failed: The module interpreter '...'
# was not found." + the three-link chain with the help_text leaf, then
# `fatal: ... {"changed": false, "module_stderr": "/bin/sh: 1: ...:
# not found\n", "module_stdout": "", "msg": "The module interpreter
# '...' was not found.", "rc": 127}` (live-captured vs 2.19.11: a
# Ubuntu 22.04 target discovered /usr/bin/python3.10 that the
# controller lacks). Krikri's plugins are native binaries, so without
# the check the task ran fine where real failed - the whole tail of the
# role (tasks, handlers, recap block count) then diverged.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# A path no machine in this suite has a python at - the check must be
# about EXISTENCE on the controller, not about which python this box
# happens to have.
private MISSING_INTERPRETER = "/usr/bin/krikri-issue-374-missing-python3.10"

private def write_playbook(root : String, module_body : String) : String
  inventory = File.join(root, "inv.ini")
  File.write(inventory, "localh ansible_connection=local ansible_python_interpreter=#{MISSING_INTERPRETER}\n")
  tasks = module_body.lines.join("\n") { |line| line.empty? ? line : "    #{line}" }
  File.write(File.join(root, "pb.yml"), "- hosts: localh\n  gather_facts: false\n  tasks:\n#{tasks}\n")
  inventory
end

private def run_playbook(root : String, inventory : String) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "connection: local task with a controller-missing interpreter" do
  it "fails the python-module task like real's deserialization failure (issue #374)" do
    root = File.tempname("local-conn-missing-interpreter")
    Dir.mkdir_p(root)
    inventory = write_playbook(root, <<-BODY
    - name: Build list of Monit configurations
      ansible.builtin.find:
        paths:
          - /etc/monit
        pattern: "*.conf.j2"
        recurse: yes
      become: no
      connection: local
      register: monit_configurations
    - name: after
      ansible.builtin.debug:
        msg: still running
BODY
    )

    status, output = run_playbook(root, inventory)

    status.success?.must_equal(false, output)
    output.must_include("[ERROR]: Task failed: Action failed: The module interpreter '#{MISSING_INTERPRETER}' was not found.", output)
    output.must_include("Task failed: Action failed.", output)
    output.must_include("<<< caused by >>>", output)
    output.must_include("The module interpreter '#{MISSING_INTERPRETER}' was not found. Consider overriding the configured interpreter path for this host. See stdout/stderr for the returned output.", output)
    output.must_include(%({"changed": false, "module_stderr": "/bin/sh: 1: #{MISSING_INTERPRETER}: not found\\n", "module_stdout": "", "msg": "The module interpreter '#{MISSING_INTERPRETER}' was not found.", "rc": 127}), output)
    output.must_include("failed=1", output)
    # The failed task halts the host like any fatal: the later task never
    # runs (that is the block-count divergence the round reported).
    output.wont_include("still running", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "does not touch a command: task - real runs it without any interpreter" do
    root = File.tempname("local-conn-missing-interpreter-command")
    Dir.mkdir_p(root)
    inventory = write_playbook(root, <<-BODY
    - name: run without python
      ansible.builtin.command: echo hi
      connection: local
      register: out
    - name: after
      ansible.builtin.debug:
        msg: "{{ out.stdout }}"
BODY
    )

    status, output = run_playbook(root, inventory)

    status.success?.must_equal(true, output)
    output.must_include("changed: [localh]", output)
    output.wont_include("was not found", output)
    output.must_include("failed=0", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
