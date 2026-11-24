require "file_utils"
require "../minitest_helper"

# loop_control's `label:` and `extended:`, both previously unimplemented -
# `label:` was ignored (the raw item was shown) and `extended:` left
# `ansible_loop` undefined, which FAILED the task outright.
#
# Every value below comes from an ansible-core 2.19.4 run of the same
# playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

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

    code.must_equal(0)
    output.must_include("item=L-one")
    output.must_include("item=L-two")
    # The raw dict must NOT be what is shown.
    output.wont_include(%(item={"n":"one"}))
  end
end

describe "loop_control: extended" do
  # index is 1-based, revindex counts down from length.
  it "exposes ansible_loop with Ansible's values" do
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

    code.must_equal(0)
    output.must_include("i=1 i0=0 rev=3 rev0=2 first=True last=False len=3 all=a+b+c")
    output.must_include("i=2 i0=1 rev=2 rev0=1 first=False last=False len=3 all=a+b+c")
    output.must_include("i=3 i0=2 rev=1 rev0=0 first=False last=True len=3 all=a+b+c")
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

    output.must_include("p=NONE n=b")
    output.must_include("p=a n=NONE")
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

    output.must_include("have=False")
  end
end

# loop_control.loop_var REPLACES "item" - ansible-core binds the item
# ONLY under the custom name: `item | default(...)` reads unset alongside a
# loop_var, and the registered per-item results carry the custom key (plus
# ansible_loop_var), never "item". Live-verified against ansible-core
# 2.19.11 (2026-09 with_items-taint round); krikri used to bind BOTH, so a
# task referencing `item` alongside its own loop_var silently worked where
# Ansible fails with "'item' is undefined".
describe "loop_control: loop_var replaces item" do
  it "does not bind item alongside the custom name" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "p={{ p }} item={{ item | default('NOITEM') }}"
            loop: [1, 2]
            loop_control:
              loop_var: p
      YAML

    code.must_equal(0)
    output.must_include("p=1 item=NOITEM")
    output.must_include("p=2 item=NOITEM")
  end

  it "registers the per-item result under the custom name only" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: produce
            ansible.builtin.debug: msg=x
            loop: [1]
            loop_control:
              loop_var: p
            register: out
          - name: inspect
            ansible.builtin.debug:
              msg: "P={{ out.results[0].p | default('NOP') }} ITEM={{ out.results[0].item | default('NOITEM') }}"
      YAML

    code.must_equal(0)
    output.must_include("P=1")
    output.must_include("ITEM=NOITEM")
  end
end

# ansible-core validates `loop_control:` at task LOAD time and refuses the
# whole run (rc=4, no play banner) for a non-mapping value, an unknown key,
# or a list/dict given to one of LoopControl's isa='string' attributes
# (loop_var, index_var, label). krikri read the mapping with as_h?/as_s?,
# silently dropped whatever it could not type and ran the play real refused
# (issue #1768 - pabluskinc.dell_powerconnect_switch's mapping `label:`).
# Messages, Origins and rc=4 live-verified against ansible-core 2.21.6.
describe "loop_control: load-time validation" do
  it "refuses a mapping label before the play starts" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: labelled
            ansible.builtin.debug: {msg: "x"}
            loop: [{n: one}]
            loop_control:
              label:
                interface: "{{ item.n }}"
      YAML

    code.must_equal(4)
    output.must_include("The field 'label' is supposed to be a string type, however the incoming data structure is a <class 'ansible.module_utils._internal._datatag._AnsibleTaggedDict'>")
    # The Origin points at the value's own start (the mapping's first key).
    output.must_match(/Origin: .*\/pb\.yml:9:11\n/)
    output.wont_include("PLAY [")
  end

  it "refuses a list label with the tagged-list class name" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: labelled
            ansible.builtin.debug: {msg: "x"}
            loop: [1]
            loop_control:
              label:
                - a
      YAML

    code.must_equal(4)
    output.must_include("_AnsibleTaggedList")
    output.wont_include("PLAY [")
  end

  it "refuses a mapping loop_var" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "x"}
            loop: [1]
            loop_control:
              loop_var:
                a: b
      YAML

    code.must_equal(4)
    output.must_include("The field 'loop_var' is supposed to be a string type")
    output.wont_include("PLAY [")
  end

  it "refuses an unknown key, Origin at the key itself" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "x"}
            loop: [1]
            loop_control:
              bogus: 1
      YAML

    code.must_equal(4)
    output.must_include("'bogus' is not a valid attribute for a LoopControl")
    output.must_match(/Origin: .*\/pb\.yml:8:9\n/)
    output.wont_include("PLAY [")
  end

  it "refuses a loop_control that is not a mapping" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "x"}
            loop: [1]
            loop_control: "{{ some_var }}"
      YAML

    code.must_equal(4)
    output.must_include("the `loop_control` value must be specified as a dictionary and cannot be a variable itself (though it can contain variables)")
    output.must_match(/Origin: .*\/pb\.yml:7:21\n/)
    output.wont_include("PLAY [")
  end

  # A null value carries no tag, so real prints the bare [ERROR] line with
  # no Origin at all - unlike every other shape above.
  it "refuses a null loop_control with no Origin" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "x"}
            loop: [1]
            loop_control:
      YAML

    code.must_equal(4)
    output.must_include("must be specified as a dictionary")
    output.wont_include("Origin:")
    output.wont_include("PLAY [")
  end
end
