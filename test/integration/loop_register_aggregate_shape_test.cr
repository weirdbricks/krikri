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
  # The invocation-echo shapes these specs pin are the machinery's own
  # behavior, exercised under ansible-core 2.21's INJECT_INVOCATION=1:
  # with the setting at its 2.21 default (off) module results carry no
  # `invocation` at all (see InvocationInjection). The key ORDER pinned
  # here is still the 2.19-era assembly; 2.21's item build reorders
  # (changed,failed,loop-vars,module keys,invocation last) - tracked in
  # UPGRADE_PLAN_221.md until the shape rework lands.
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir,
    env: {"ANSIBLE_INJECT_INVOCATION" => "1"})
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
    output.must_include("failed=False msg=All items completed")
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
    output.must_include("KEYS|changed,failed,ansible_loop_var,item,stat,invocation")
  end
end

# Real appends `invocation` at the END of the module's own dict, ahead of the
# stdout_lines/stderr_lines the command/shell action plugin derives afterwards
# (live-verified 2.19.11 on the success, non-zero-rc, creates-skipped and
# check-skipped item shapes). A free-form `shell:`/`command:` also reaches the
# module with its argument folded into `_raw_params`, so `_raw_params` - not
# `cmd` - is the single SUPPLIED option and leads `invocation.module_args`,
# while `cmd` falls back into its declaration-order slot among the null
# defaults (zzet.rbenv's nested loop over registered shell results, #673).
# Both tasks declare `changed_when: false`, and real's item result carries
# the verdict right after the declared fields' msg/rc, ahead of the loop
# wrapper keys (live-verified vs 2.21.6).
describe "command/shell loop-item register key order" do
  it "places invocation after msg and folds the free-form arg into _raw_params" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.shell: $0 -lc true
            loop: [a, b]
            register: rr
            changed_when: false
          - ansible.builtin.debug:
              msg: "KEYS|{{ rr.results[0] | dict2items | map(attribute='key') | join(',') }}"
          - ansible.builtin.debug:
              msg: "ARGS|{{ rr.results[0].invocation.module_args | dict2items | map(attribute='key') | join(',') }}"
          - ansible.builtin.debug:
              msg: "RP|{{ rr.results[0].invocation.module_args._raw_params }}|CMD|{{ rr.results[0].invocation.module_args.cmd }}"
      YAML

    code.must_equal(0)
    output.must_include("KEYS|changed,failed,msg,rc,changed_when_result,ansible_loop_var,item,stdout,stderr,cmd,start,end,delta,invocation,stdout_lines,stderr_lines")
    output.must_include("ARGS|_raw_params,_uses_shell,expand_argument_vars,stdin_add_newline,strip_empty_ends,cmd,argv,chdir,executable,creates,removes,stdin")
    output.must_include("RP|$0 -lc true|CMD|")
  end

  # The keyed form is the opposite fold: `cmd` IS the supplied option, so it
  # leads module_args and `_raw_params` stays null in its declaration slot.
  it "keeps cmd as the supplied option for a keyed shell: task" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.shell:
              cmd: $0 -lc true
            loop: [a]
            register: rr
            changed_when: false
          - ansible.builtin.debug:
              msg: "KEYS|{{ rr.results[0] | dict2items | map(attribute='key') | join(',') }}"
          - ansible.builtin.debug:
              msg: "ARGS|{{ rr.results[0].invocation.module_args | dict2items | map(attribute='key') | join(',') }}"
      YAML

    code.must_equal(0)
    output.must_include("KEYS|changed,failed,msg,rc,changed_when_result,ansible_loop_var,item,stdout,stderr,cmd,start,end,delta,invocation,stdout_lines,stderr_lines")
    output.must_include("ARGS|cmd,_uses_shell,expand_argument_vars,stdin_add_newline,strip_empty_ends,_raw_params,argv,chdir,executable,creates,removes,stdin")
  end
end
