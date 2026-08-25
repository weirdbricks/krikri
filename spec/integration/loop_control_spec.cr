require "file_utils"
require "../spec_helper"

# loop_control's `label:` and `extended:`, both previously unimplemented -
# `label:` was ignored (the raw item was shown) and `extended:` left
# `ansible_loop` undefined, which FAILED the task outright.
#
# Every value below comes from an ansible-core 2.19.4 run of the same
# playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_play(playbook : String) : {Int32, String}
  dir = File.tempname("loop-control")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "loop_control: label" do
  it "shows the rendered label instead of the raw item" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: labelled
            ansible.builtin.debug: {msg: "x"}
            loop: [{n: one}, {n: two}]
            loop_control:
              label: "L-{{ item.n }}"
      YAML

    code.should eq(0)
    output.should contain("item=L-one")
    output.should contain("item=L-two")
    # The raw dict must NOT be what is shown.
    output.should_not contain(%(item={"n":"one"}))
  end
end

describe "loop_control: extended" do
  # index is 1-based, revindex counts down from length.
  it "exposes ansible_loop with real Ansible's values" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "i={{ ansible_loop.index }} i0={{ ansible_loop.index0 }} rev={{ ansible_loop.revindex }} rev0={{ ansible_loop.revindex0 }} first={{ ansible_loop.first }} last={{ ansible_loop.last }} len={{ ansible_loop.length }} all={{ ansible_loop.allitems | join('+') }}"
            loop: [a, b, c]
            loop_control:
              extended: true
      YAML

    code.should eq(0)
    output.should contain("i=1 i0=0 rev=3 rev0=2 first=True last=False len=3 all=a+b+c")
    output.should contain("i=2 i0=1 rev=2 rev0=1 first=False last=False len=3 all=a+b+c")
    output.should contain("i=3 i0=2 rev=1 rev0=0 first=False last=True len=3 all=a+b+c")
  end

  # nextitem/previtem are ABSENT at the ends, not null - so a playbook
  # uses `| default(...)` there, and that must actually kick in.
  it "omits nextitem on the last item and previtem on the first" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "p={{ ansible_loop.previtem | default('NONE') }} n={{ ansible_loop.nextitem | default('NONE') }}"
            loop: [a, b]
            loop_control:
              extended: true
      YAML

    output.should contain("p=NONE n=b")
    output.should contain("p=a n=NONE")
  end

  # Guard: without extended: there is no ansible_loop, and a loop that
  # does not ask for it is unaffected.
  it "does not define ansible_loop unless asked" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "have={{ ansible_loop is defined }}"
            loop: [a]
      YAML

    output.should contain("have=False")
  end
end
