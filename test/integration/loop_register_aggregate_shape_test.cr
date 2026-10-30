require "file_utils"
require "../minitest_helper"

# Ansible's loop-aggregate register shape (ansible-core's itemized
# task handler): `failed` is only present when an item actually failed,
# and `msg` is "All items completed" / "One or more items failed". The
# aggregate previously always carried failed: false and no msg, so
# `r.failed | default('none')` printed False where Ansible prints None
# (live-verified against ansible-playbook 2.14 in the podman-diff
# harness, git_config GC14).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String) : {Int32, String}
  dir = File.tempname("loop-register")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "looped-task register aggregate shape" do
  it "omits failed and reports All items completed when every item succeeds" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "x"
            loop: [a, b]
            register: r
          - ansible.builtin.debug:
              msg: "failed={{ r.failed | default('none') }} msg={{ r.msg }}"
      YAML

    code.must_equal(0)
    output.must_include("failed=none")
    output.must_include("msg=All items completed")
  end

  it "reports failed: true and One or more items failed when an item fails" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.command: /bin/false
            loop: [a, b]
            register: r
            ignore_errors: true
          - ansible.builtin.debug:
              msg: "failed={{ r.failed }} msg={{ r.msg }}"
      YAML

    code.must_equal(0)
    output.must_include("failed=True")
    output.must_include("msg=One or more items failed")
  end
end

# Real's loop-registered stat item orders invocation BEFORE the trailing
# failed: false (round 5410000, pacifica.ansible_certinfra's nested
# stat-result loop; single-task stat registers carry NO invocation at all,
# probed 2026-10-10 - krikri's single-task path already matches that).
describe "stat loop-item register key order" do
  it "reads changed/stat/invocation/failed like real's loop item" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.stat:
              path: /nonexistent-kp
            loop: [a, b]
            register: rr
          - ansible.builtin.debug:
              msg: "KEYS|{{ rr.results[0] | dict2items | map(attribute='key') | join(',') }}"
      YAML

    code.must_equal(0)
    output.must_include("KEYS|changed,stat,invocation,failed")
  end
end

# Real's module-side _return_formatted adds `invocation` BEFORE deriving
# stdout_lines/stderr_lines (live capture, issue #672 zorlin.rust
# round29884741: the registered shell loop item reads .../msg/invocation/
# stdout_lines/stderr_lines/failed), and a free-form command arrives as
# Ansible's OWN supplied arg `_raw_params` (sorted first in module_args)
# while `cmd` stays a never-supplied null default - krikri's params carry
# the command as `cmd`, so both key SLOTS must swap, not just the values.
describe "shell loop-item register key order" do
  it "reads msg/invocation/stdout_lines/stderr_lines/failed like real's loop item" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.shell: "echo hi | cat"
            loop: [one]
            register: r
            changed_when: false
          - ansible.builtin.debug:
              msg: "KEYS|{{ r.results[0] | dict2items | map(attribute='key') | join(',') }}"
      YAML

    code.must_equal(0)
    output.must_include("KEYS|changed,stdout,stderr,rc,cmd,start,end,delta,msg,invocation,stdout_lines,stderr_lines,failed")
  end

  it "orders module_args with _raw_params supplied-first and cmd among the nulls" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.shell: "echo hi | cat"
            loop: [one]
            register: r
            changed_when: false
          - ansible.builtin.debug:
              msg: "ARGS|{{ r.results[0].invocation.module_args | dict2items | map(attribute='key') | join(',') }}"
      YAML

    code.must_equal(0)
    output.must_include("ARGS|_raw_params,_uses_shell,expand_argument_vars,stdin_add_newline,strip_empty_ends,cmd,argv,chdir,executable,creates,removes,stdin")
  end
end
