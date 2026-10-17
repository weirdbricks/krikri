require "../minitest_helper"
require "file_utils"

# Issue #149: a free-form (non-command) args string containing an unquoted,
# whitespace-separated token that BEGINS with `{%` makes ansible-core render
# the whole string as one Jinja template and fail finalization with
# "Task args must resolve to a 'dict' not '<Type>'" - 'NoneType' when no
# `{% %}` block contributed any output, 'str' when at least one did
# (observed vs ansible-core 2.19.11). Quoted `{%` text and raw command
# modules keep parsing/running.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "free-form args with an unquoted {% block token" do
  it "fails finalization with 'NoneType' for the issue repro shape (empty conditional)" do
    playbook = File.tempname("jinja-block-args", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          v: "1.0"
          p: "/tmp/venv"
          pip_args: ""
        tasks:
          - ansible.builtin.pip: >-
              name=supervisor version={{ v }} virtualenv={{ p }} use_mirrors=no
              {% if pip_args %} extra_args={{ pip_args }} {% endif %}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Task failed: Finalization of task args for 'ansible.builtin.pip' failed: Task args must resolve to a 'dict' not 'NoneType'.")
    # the pre-fix krikri failure shape must be gone: the module never sees
    # its parsed params at all
    text.wont_include("Unsupported parameters")
    text.wont_include("use_mirrors")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "warns (argsplat) and points the string-layer Origins at the free-form value" do
    playbook = File.tempname("jinja-block-args", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          pip_args: ""
        tasks:
          - name: installing supervisor
            pip: name=supervisor
                 version=4.2.5 use_mirrors=no
                 {% if pip_args %} extra_args={{ pip_args }} {% endif %}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # Ansible prints the argsplat warning for the string args layer BEFORE
    # the finalization ERROR (live-captured 2.19.11), and both the
    # warning's Origin and the error chain's innermost Origin sit at the
    # free-form value's first character (`pip: name=supervisor` ->
    # column 12), not the module key (column 7); the outer two chain
    # frames keep the task-name and module-key positions.
    text.must_include("[WARNING]: Using a template for task args is unsafe in some situations")
    warning = text.match(/\[WARNING\][^\n]*\nOrigin: [^\n]*\.yml:(\d+):(\d+)/)
    warning.wont_be_nil
    warning.not_nil![2].to_i.must_equal(12)
    text.must_include("Task failed.\nOrigin: #{playbook}:6:7")
    text.must_include("Finalization of task args for 'ansible.builtin.pip' failed.\nOrigin: #{playbook}:7:7")
    inner = text.match(/Task args must resolve[^\n]*\nOrigin: [^\n]*\.yml:(\d+):(\d+)/)
    inner.wont_be_nil
    inner.not_nil![2].to_i.must_equal(12)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails finalization with 'str' when a block contributes output" do
    playbook = File.tempname("jinja-block-args", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: msg=hi {% if true %}x{% endif %} var=1
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Task args must resolve to a 'dict' not 'str'.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "runs the task normally when the {% block is quoted" do
    playbook = File.tempname("jinja-block-args", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: msg="hi {% if true %}x{% endif %}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("hi x")
    text.wont_include("Task args must resolve")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps command: working with mid-string and delimiter-wrapped blocks" do
    playbook = File.tempname("jinja-block-args", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.command: echo {% if true %}hi{% endif %}
          - ansible.builtin.command: "{% if true %}echo hi2{% endif %}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "-v", playbook], output: output, error: output)
    text = output.to_s

    text.must_include("hi")
    text.must_include("hi2")
    text.wont_include("Task args must resolve")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
