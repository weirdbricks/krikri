require "file_utils"
require "../minitest_helper"

# `debugger:` - drop into an interactive prompt when a task reaches the
# configured condition. Behaviors checked against ansible-core 2.19.4.
#
# Note the debugger reads stdin even when it is NOT a terminal, unlike
# vars_prompt: piping "c" continues, and closing stdin is treated as an
# interrupt (exit 99).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

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
    code.must_equal(99)
    output.must_include("User interrupted execution")
  end

  it "continues on c, leaving the task's own exit code" do
    code, output = run_debug(FAILING, "c\n")
    code.must_equal(2)
    output.must_include("(debug)>")
  end

  it "quits on q with the interrupt code" do
    code, _ = run_debug(FAILING, "q\n")
    code.must_equal(99)
  end

  it "prints the result with p" do
    _, output = run_debug(FAILING, "p result\nc\n")
    output.must_include("(debug)>")
    output.must_include(%("failed":true))
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

    code.must_equal(0)
    output.scan("(debug)>").size.must_equal(1)
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
    code.must_equal(2)
    output.wont_include("(debug)>")

    plain_code, plain_output = run_debug(<<-YAML, nil)
      - hosts: all
        gather_facts: false
        tasks:
          - name: fails
            ansible.builtin.command: /bin/false
      YAML
    plain_code.must_equal(2)
    plain_output.wont_include("(debug)>")
  end

  # Assignment from the prompt - real Ansible does this by exec'ing the
  # typed line as Python; this parses the two shapes that make the
  # debugger useful and applies them to the real task/vars. Every
  # expectation below was checked against ansible-core 2.19.4 driving the
  # equivalent playbook with the same piped input, recap counts included.
  # The classic suite assigned this to a describe-body local (visible to
  # the closure its); minitest's describe bodies are class bodies, so it
  # becomes a method.
  private def templated_playbook : String
    <<-YAML
  - hosts: all
    gather_facts: false
    vars:
      exit_code: "1"
    tasks:
      - name: exits with a var-controlled code
        ansible.builtin.command: "/bin/sh -c 'exit {{ exit_code }}'"
        debugger: on_failed
      - name: after
        ansible.builtin.debug:
          msg: reached
  YAML
  end

  describe "assignment" do
    it "applies task.args[...] and re-runs it on r" do
      # `_raw_params` is real Ansible's name for a command:'s free-form
      # argument; this engine stores it as `cmd` and aliases the two.
      code, output = run_debug(FAILING, %(task.args["_raw_params"] = "/bin/true"\nr\n))
      code.must_equal(0)
      output.must_include("changed=1")
      output.wont_include("failed=1")
    end

    it "does NOT change the task on a task_vars assignment alone - u is required" do
      # Verified against real Ansible: assign + r re-runs the ORIGINAL
      # command, because its task object is already templated by then.
      code, _ = run_debug(templated_playbook, %(task_vars["exit_code"] = "0"\nr\nc\n))
      code.must_equal(2)
    end

    it "re-templates the task from updated task_vars on u, and then r passes" do
      code, output = run_debug(templated_playbook, %(task_vars["exit_code"] = "0"\nu\nr\nc\n))
      code.must_equal(0)
      output.must_include("reached")
    end

    it "shows the templated arguments with p task.args, reflecting an applied edit" do
      _, output = run_debug(templated_playbook, %(task_vars["exit_code"] = "0"\nu\np task.args\nc\n))
      output.must_include("exit 0")
    end

    it "refuses a value it cannot parse instead of pretending the assignment took" do
      _, output = run_debug(FAILING, %(task.args["chdir"] = some_python_expr()\nc\n))
      output.must_include("***ValueError")
    end

    it "still reports a genuinely unknown command" do
      _, output = run_debug(FAILING, "wat\nc\n")
      output.must_include("Unknown command: wat")
    end
  end
end
