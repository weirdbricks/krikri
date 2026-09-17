require "file_utils"
require "../spec_helper"

# `omit` - real Ansible's magic value for "drop this entirely rather
# than giving it any real value". This engine represents it internally
# as the OMIT_SENTINEL string, which used to LEAK as literal text
# (`__crystal_ansible_omit__`) everywhere except the one case that
# checked for it: a module parameter whose whole value was omit.
#
# Every expectation here was checked against ansible-core 2.19.4 running
# the equivalent playbook, recap counts included.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_omit(tasks : String) : {Int32, String}
  dir = File.tempname("omit")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
  - hosts: all
    gather_facts: false
    vars:
      v_omit: "{{ never_set | default(omit) }}"
      real_val: kept
    tasks:
  #{tasks}
  YAML

  io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: io, error: io, chdir: dir)
  {status.exit_code, io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "omit" do
  it "renders as nothing when it is only PART of a larger value" do
    # Real Ansible prints "[]" here; this engine printed
    # "[__crystal_ansible_omit__]", so its own sentinel reached logs,
    # config files and command lines as if it were real content.
    code, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "[{{ v_omit }}]"
      YAML
    code.should eq(0)
    output.should contain("[]")
    output.should_not contain("__crystal_ansible_omit__")
  end

  it "accepts a BARE {{ omit }}, which used to fail the task as undefined" do
    # `omit` is a magic bareword, not a variable anyone sets, so the
    # strict module-arg check reported "'omit' is undefined" and failed
    # the task. Real Ansible prints "[]".
    code, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "[{{ omit }}]"
      YAML
    code.should eq(0)
    output.should contain("[]")
    output.should_not contain("is undefined")
  end

  it "collapses several omits in one string" do
    _, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "x{{ v_omit }}y{{ omit }}z"
      YAML
    output.should contain("xyz")
  end

  it "still drops the parameter entirely when omit is the WHOLE value" do
    # The behavior omit exists for, and the reason the empty-string
    # mapping has to happen AFTER the whole-value check: debug: with no
    # msg: falls back to its own default.
    _, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ v_omit }}"
      YAML
    output.should contain("Hello world!")
  end

  it "is removed from a list literal rather than left as a placeholder" do
    _, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ [1, v_omit, 3] }}"
      YAML
    # A whole-span `{{ expr }}` module arg is natively typed like real
    # Ansible's own module args (live-verified vs ansible-playbook
    # 2.19.11: `debug: msg: "{{ [1, omit, 3] }}"` prints msg as a real
    # LIST, pretty-printed by the callback) - the wire carries this
    # codebase's double-quoted JSON container form.
    output.should contain("[1,3]")
  end

  it "drops its whole key in a dict literal" do
    _, output = run_omit(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ {'a': 1, 'b': v_omit} }}"
      YAML
    # Same whole-span native typing as above (live-verified: real
    # Ansible prints msg as a real dict with only the omit key dropped).
    output.should contain(%({"a":1}))
  end

  it "does not swallow genuinely falsy values alongside it" do
    # "", 0 and false are real values real Ansible keeps - only omit
    # goes. A reject that tested truthiness instead of identity would
    # eat all four.
    _, output = run_omit(<<-YAML)
        - name: list
          ansible.builtin.debug:
            msg: "{{ [real_val, v_omit, '', 0, false] }}"
        - name: dict
          ansible.builtin.debug:
            msg: "{{ {'a': 0, 'b': false, 'c': '', 'd': v_omit} }}"
      YAML
    # Same whole-span native typing as above (live-verified: real
    # Ansible keeps "", 0 and False in the natively-typed containers).
    output.should contain(%(["kept","",0,false]))
    output.should contain(%({"a":0,"b":false,"c":""}))
  end

  it "treats a block-tag template rendering to nothing as omitted, not empty" do
    # hbjydev.restic's own content: "{% for f in restic_files %}{{ f
    # }}\n{% endfor %}" with restic_files: [] - live-verified vs
    # ansible-core 2.19.11: real Ansible fails copy's own "src (or
    # content) is required" check here, unlike a bare `{{ empty_var
    # }}"`/literal `""` content (both succeed and write a real empty
    # file - see copy_empty_content_spec.cr). The block tag's own empty
    # render is functionally indistinguishable from an unset param, so
    # this dedicated OMIT path in substitute_task_params drops the
    # param key entirely rather than sending copy.cr a literal "".
    dir = File.tempname("omit-block-tag")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    dest = File.join(dir, "out.conf")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
      vars:
        restic_files: []
      tasks:
        - name: t
          ansible.builtin.copy:
            dest: #{dest}
            content: "{% for f in restic_files %}{{ f }}\\n{% endfor %}"
          ignore_errors: true
          register: r
        - ansible.builtin.debug:
            msg: "MSG={{ r.msg | default('OK') }}"
    YAML

    io = IO::Memory.new
    Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: io, error: io, chdir: dir)
    output = io.to_s
    output.should contain("MSG=src (or content) is required")
    File.exists?(dest).should be_false
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
