require "file_utils"
require "../spec_helper"

# `no_log: true` is a SECURITY control - it is how a playbook keeps a
# password, token or key out of the log. It was unparsed and unused, so
# every such task printed its secret in full.
#
# Real ansible-playbook (2.19.4) shows the task banner and the status
# line and NOTHING else for such a task, and leaks nothing even under
# -v. These specs assert on the secret never appearing, which is the
# property that actually matters.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_play(playbook : String, args : Array(String) = Array(String).new)
  dir = File.tempname("no-log")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini"] + args + ["pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "no_log:" do
  it "hides a command's output and a debug msg" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: secret task
            ansible.builtin.command: echo SUPERSECRET123
            no_log: true
          - name: secret debug
            ansible.builtin.debug: {msg: "TOPSECRET456"}
            no_log: true
      YAML

    output.should_not contain("SUPERSECRET123")
    output.should_not contain("TOPSECRET456")
    # The task still reports its status, as real Ansible does.
    output.should contain("secret task")
    output.should contain("changed: [localhost]")
  end

  it "does not leak under -v either" do
    _, output = run_play(<<-YAML, ["-v"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: secret debug
            ansible.builtin.debug: {msg: "TOPSECRET456"}
            no_log: true
      YAML

    output.should_not contain("TOPSECRET456")
  end

  # The failure path prints through a different branch than the ok path,
  # and is exactly where a secret would otherwise be dumped as error
  # detail.
  it "hides the error detail of a FAILING task" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: failing secret
            ansible.builtin.command: sh -c "echo FAILSECRET789 >&2; exit 1"
            no_log: true
            ignore_errors: true
      YAML

    output.should_not contain("FAILSECRET789")
  end

  it "hides every item of a looped task" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: looped secret
            ansible.builtin.debug: {msg: "LOOPSECRET-{{ item }}"}
            no_log: true
            loop: [a, b]
      YAML

    output.should_not contain("LOOPSECRET")
  end

  # A handler is as capable of holding a secret as any other task, and
  # has its own display path.
  it "hides a handler's output" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: h
        handlers:
          - name: h
            ansible.builtin.debug: {msg: "HANDLERSECRET"}
            no_log: true
      YAML

    output.should_not contain("HANDLERSECRET")
  end

  # Guard against over-reach: without no_log the output is still shown.
  it "leaves output visible when no_log is absent" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: normal
            ansible.builtin.debug: {msg: "VISIBLE123"}
      YAML

    output.should contain("VISIBLE123")
  end
end
