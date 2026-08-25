require "file_utils"
require "../spec_helper"

# `debugger:` - drop into an interactive prompt when a task reaches the
# configured condition. Behaviors checked against ansible-core 2.19.4.
#
# Note the debugger reads stdin even when it is NOT a terminal, unlike
# vars_prompt: piping "c" continues, and closing stdin is treated as an
# interrupt (exit 99).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_debug(playbook : String, input : String?) : {Int32, String}
  dir = File.tempname("debugger")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir,
    input: input ? IO::Memory.new(input) : Process::Redirect::Close)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private FAILING = <<-YAML
  - hosts: all
    gather_facts: false
    tasks:
      - name: fails
        ansible.builtin.command: /bin/false
        debugger: on_failed
  YAML

describe "debugger:" do
  # EOF is real Ansible's "user interrupted execution", exit 99 - NOT
  # the ordinary failed-task 2.
  it "treats a closed stdin as an interrupt, exiting 99" do
    code, output = run_debug(FAILING, nil)
    code.should eq(99)
    output.should contain("User interrupted execution")
  end

  it "continues on c, leaving the task's own exit code" do
    code, output = run_debug(FAILING, "c\n")
    code.should eq(2)
    output.should contain("(debug)>")
  end

  it "quits on q with the interrupt code" do
    code, _ = run_debug(FAILING, "q\n")
    code.should eq(99)
  end

  it "prints the result with p" do
    _, output = run_debug(FAILING, "p result\nc\n")
    output.should contain("(debug)>")
    output.should contain(%("failed":true))
  end

  # always fires even for a task that succeeded.
  it "fires on a successful task for always" do
    code, output = run_debug(<<-YAML, "c\n")
      - hosts: all
        gather_facts: false
        tasks:
          - name: ok task
            ansible.builtin.debug: {msg: "HI"}
            debugger: always
      YAML

    code.should eq(0)
    output.scan("(debug)>").size.should eq(1)
  end

  # never, and the absence of the keyword, must not prompt at all -
  # otherwise an ordinary run would block forever on a closed stdin.
  it "does not fire for never, nor when the keyword is absent" do
    code, output = run_debug(<<-YAML, nil)
      - hosts: all
        gather_facts: false
        tasks:
          - name: fails
            ansible.builtin.command: /bin/false
            debugger: never
      YAML
    code.should eq(2)
    output.should_not contain("(debug)>")

    plain_code, plain_output = run_debug(<<-YAML, nil)
      - hosts: all
        gather_facts: false
        tasks:
          - name: fails
            ansible.builtin.command: /bin/false
      YAML
    plain_code.should eq(2)
    plain_output.should_not contain("(debug)>")
  end
end
