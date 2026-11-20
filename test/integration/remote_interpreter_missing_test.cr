require "../minitest_helper"
require "socket"

# Issue #1646: a module task whose configured interpreter
# (ansible_python_interpreter) does not exist on the TARGET. Real resolves
# that path for every module payload, so the run dies with rc 127 and a
# non-JSON stdout, which its action layer reports as the
# module-interpreter-not-found action failure:
#
#   [ERROR]: Task failed: Action failed: The module interpreter
#   '/usr/bin/python2' was not found.
#   ...
#   <<< caused by >>>
#   The module interpreter '/usr/bin/python2' was not found. Consider
#   overriding the configured interpreter path for this host. See
#   stdout/stderr for the returned output.
#   fatal: [target]: FAILED! => {"changed": false, "module_stderr":
#   "Shared connection to <host> closed.\r\n", "module_stdout":
#   "/bin/sh: 1: /usr/bin/python2: not found\r\n", "msg": "The module
#   interpreter '/usr/bin/python2' was not found.", "rc": 127}
#
# (live-captured vs ansible-core 2.21.6 over ssh with pipelining off, the
# default - t_woerner.ipareplica's round shows the identical shape).
# krikri's modules are compiled binaries that never run python, so without
# a target-side check the task ran fine where real failed - the round's
# "Set python interpreter to 2" skip and the ipaclient_test fatal both
# followed from it.
#
# Needs a real sshd reachable from the controller (the check only exists
# off the local connection) - it skips without one. The throwaway server
# task_timeout_ssh_loop_test.cr's header documents works; override
# KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY to point elsewhere.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private SSHD_HOST = ENV["KRIKRI_TEST_SSHD_HOST"]? || "127.0.0.1"
private SSHD_PORT = (ENV["KRIKRI_TEST_SSHD_PORT"]? || "2224").to_i
private SSHD_USER = ENV["KRIKRI_TEST_SSHD_USER"]? || "root"
private SSHD_KEY  = ENV["KRIKRI_TEST_SSHD_KEY"]? || "/tmp/kkt-key"

private MISSING_INTERPRETER = "/usr/bin/krikri-issue-1646-missing-python2"

private def sshd_reachable? : Bool
  return false unless File.exists?(SSHD_KEY)
  TCPSocket.new(SSHD_HOST, SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

private def write_remote_interpreter_case(interpreter : String) : {String, String}
  playbook = PluginSpecHelper.tmp_path("remote-interpreter-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, [
    "- hosts: target",
    "  gather_facts: false",
    "  vars:",
    "    ansible_python_interpreter: #{interpreter}",
    "  tasks:",
    "    - name: Find something with the configured interpreter",
    "      ansible.builtin.find:",
    "        paths: /tmp",
    "    - name: after",
    "      ansible.builtin.debug:",
    "        msg: still running",
    "",
  ].join("\n"))
  inventory = PluginSpecHelper.tmp_path("remote-interpreter-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} " \
                        "ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} " \
                        "ansible_ssh_private_key_file=#{SSHD_KEY} " \
                        "ansible_ssh_common_args='-o StrictHostKeyChecking=no " \
                        "-o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")
  {playbook, inventory}
end

private def run_remote_interpreter_case(interpreter : String) : {Process::Status, String, String, String}
  playbook, inventory = write_remote_interpreter_case(interpreter)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
  {status, output.to_s, playbook, inventory}
end

describe "module interpreter missing on the ssh target" do
  it "fails a module task with real's interpreter-not-found block (issue #1646)" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    status, output, playbook, inventory = run_remote_interpreter_case(MISSING_INTERPRETER)

    status.success?.must_equal(false, output)
    output.must_include("[ERROR]: Task failed: Action failed: The module interpreter '#{MISSING_INTERPRETER}' was not found.", output)
    output.must_include("Task failed: Action failed.", output)
    output.must_include("<<< caused by >>>", output)
    output.must_include("The module interpreter '#{MISSING_INTERPRETER}' was not found. Consider overriding the configured interpreter path for this host. See stdout/stderr for the returned output.", output)
    # The non-pipelined ssh session's pty carries the shell's own line on
    # stdout and leaves only the client's close notice on stderr; the
    # target's /bin/sh decides dash's "1:" wording vs bash's "line 1:".
    output.must_include(%("module_stderr": "Shared connection to #{SSHD_HOST} closed.\\r\\n"), output)
    output.must_match(/"module_stdout": "\/bin\/sh: (?:1: |line 1: )#{Regex.escape(MISSING_INTERPRETER)}: (?:not found|No such file or directory)\\r\\n"/, output)
    output.must_include(%("msg": "The module interpreter '#{MISSING_INTERPRETER}' was not found.", "rc": 127), output)
    output.must_include("failed=1", output)
    # Fatal for the host like any other: the later task never runs.
    output.wont_include("still running", output)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(inventory) if inventory && File.exists?(inventory)
  end

  it "runs the task when the configured interpreter exists on the target" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    # A probe-sanity check rather than a parity transcript: /bin/sh exists
    # on every target, so the verdict must be "present" and the task must
    # run. A probe that misreads an answered "present" as missing would
    # fail tasks real runs fine.
    status, output, playbook, inventory = run_remote_interpreter_case("/bin/sh")

    status.success?.must_equal(true, output)
    output.wont_include("was not found", output)
    output.must_include("still running", output)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(inventory) if inventory && File.exists?(inventory)
  end
end
