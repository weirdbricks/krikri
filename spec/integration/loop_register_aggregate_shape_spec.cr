require "file_utils"
require "../spec_helper"

# Real Ansible's loop-aggregate register shape (ansible-core's itemized
# task handler): `failed` is only present when an item actually failed,
# and `msg` is "All items completed" / "One or more items failed". The
# aggregate previously always carried failed: false and no msg, so
# `r.failed | default('none')` printed False where real prints None
# (live-verified against real ansible-playbook 2.14 in the podman-diff
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

    code.should eq(0)
    output.should contain("failed=none")
    output.should contain("msg=All items completed")
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

    code.should eq(0)
    output.should contain("failed=True")
    output.should contain("msg=One or more items failed")
  end
end
