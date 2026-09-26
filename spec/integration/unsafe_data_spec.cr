require "../spec_helper"
require "file_utils"

# Security regression specs: data returned by managed hosts (module
# results, gathered facts, set_fact values computed from them, loop items
# taken from them) is "unsafe" exactly like real ansible-core's
# AnsibleUnsafe marking - it must be passed through VERBATIM on every
# evaluation path, never re-rendered as Jinja. Before this was fixed, a
# hostile target returning stdout shaped like `{{ lookup('pipe', ...) }}`
# got that lookup EXECUTED on the controller through `when:`, `debug:
# var=`, `set_fact` + later use, loop items, `assert:`, and gathered
# facts - controller code execution from module output.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

# Runs the binary on a register-then-consume playbook and reports whether
# the hostile `lookup('pipe', ...)` inside the module result executed on
# the controller (canary file created).
#
# *consume_tasks*: the consuming task(s). Heredoc convention: the task
# dash sits at the heredoc's own strip level (the closing YAML marker's
# indentation, which ameba's Style/HeredocIndent pins to opener+2), so
# after stripping, dash = 0 / keys = 2; every non-empty line gets the
# play's 4-space task level prefixed here, landing the consumer at
# exactly the same level as the producer task.
private def hostile_run(consume_tasks : String, *, canary : String)
  playbook = File.tempname("unsafe-data", ".yml")
  File.open(playbook, "w") do |file|
    file.puts "- name: unsafe-data repro"
    file.puts "  hosts: all"
    file.puts "  gather_facts: false"
    file.puts "  tasks:"
    file.puts "    - name: produce hostile output"
    file.puts %(      ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}")
    file.puts "      register: r"
    consume_tasks.each_line do |line|
      file.puts line.empty? ? "" : "    " + line
    end
  end

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def assert_not_executed(playbook_body : String, *, label : String, file : String = __FILE__, line : Int32 = __LINE__)
  it "never re-renders a hostile module result via #{label}", file, line do
    canary = File.tempname("unsafe-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(playbook_body, canary: canary)
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via #{label}:\n#{output}"
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end
end

describe "unsafe module results are never re-templated" do
  assert_not_executed(<<-YAML, label: "when: r.stdout | length > 0")
    - name: consume
      ansible.builtin.debug: msg=hi
      when: r.stdout | length > 0
    YAML

  assert_not_executed(<<-YAML, label: "debug: var=r.stdout")
    - name: consume
      ansible.builtin.debug: var=r.stdout
    YAML

  assert_not_executed(<<-YAML, label: "set_fact then debug var=")
    - name: stage
      ansible.builtin.set_fact:
        x: "{{ r.stdout }}"
    - name: consume
      ansible.builtin.debug: var=x
    YAML

  assert_not_executed(<<-YAML, label: %(set_fact then when: x != ""))
    - name: stage
      ansible.builtin.set_fact:
        x: "{{ r.stdout }}"
    - name: consume
      ansible.builtin.debug: msg=hi
      when: x != ""
    YAML

  assert_not_executed(<<-YAML, label: %(loop over r.stdout_lines with msg={{ item }}))
    - name: consume
      ansible.builtin.debug: msg="{{ item }}"
      loop: "{{ r.stdout_lines }}"
    YAML

  assert_not_executed(<<-YAML, label: "assert: that: r.stdout is defined")
    - name: consume
      ansible.builtin.assert:
        that: r.stdout is defined
    YAML

  assert_not_executed(<<-YAML, label: "when: r.stdout is defined")
    - name: consume
      ansible.builtin.debug: msg=hi
      when: r.stdout is defined
    YAML

  it "prints a hostile module result verbatim via debug var= (real-Ansible parity)" do
    canary = File.tempname("unsafe-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: var=r.stdout
      YAML
    status.success?.should be_true, output.to_s
    # Real ansible-core prints the unsafe text verbatim - the braces must
    # still be there, not rendered away.
    output.to_s.should contain("{{ lookup('pipe', 'touch #{canary}') }}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "fails a scalar `loop:` source without executing its hostile text" do
    # `loop: "{{ r.stdout }}"` resolves to a STRING - real Ansible fails
    # the task ("The `loop` value must resolve to a 'list', not 'str'.")
    # without ever templating the failed source's text.
    canary = File.tempname("unsafe-loop-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="{{ item }}"
        loop: "{{ r.stdout }}"
      YAML
    status.success?.should be_false, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a failing loop source:\n#{output}"
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "never re-renders hostile data gathered as local facts (ansible_local)" do
    canary = File.tempname("unsafe-fact-canary")
    File.delete(canary) if File.exists?(canary)
    facts_dir = File.tempname("unsafe-facts-dir")
    Dir.mkdir(facts_dir)
    File.write(File.join(facts_dir, "evil.fact"),
      %({"v": "{{ lookup('pipe', 'touch #{canary}') }}"}))
    playbook = File.tempname("unsafe-facts", ".yml")
    File.write(playbook, <<-YAML)
      - name: unsafe local facts
        hosts: all
        gather_facts: false
        tasks:
          - name: gather
            ansible.builtin.setup:
              fact_path: #{facts_dir}
          - name: consume via debug var
            ansible.builtin.debug: var=ansible_local.evil.v
          - name: consume via when
            ansible.builtin.debug: msg=hi
            when: ansible_local.evil.v | length > 0
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via gathered facts:\n#{output}"
    output.to_s.should contain("{{ lookup('pipe', 'touch #{canary}') }}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    FileUtils.rm_rf(facts_dir) if facts_dir && Dir.exists?(facts_dir)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "!unsafe-tagged YAML values are never templated" do
  it "passes an !unsafe value through verbatim on msg= and var= paths" do
    canary = File.tempname("unsafe-tag-canary")
    File.delete(canary) if File.exists?(canary)
    playbook = File.tempname("unsafe-tag", ".yml")
    File.write(playbook, <<-YAML)
      - name: unsafe tag
        hosts: all
        gather_facts: false
        vars:
          secret: !unsafe "{{ lookup('pipe', 'touch #{canary}') }}"
        tasks:
          - name: via msg
            ansible.builtin.debug: msg="v={{ secret }}"
          - name: via var
            ansible.builtin.debug: var=secret
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "an !unsafe value was templated (lookup executed):\n#{output}"
    output.to_s.should contain("{{ lookup('pipe', 'touch #{canary}') }}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "author-defined template vars still render recursively (legitimate behavior preserved)" do
  it "renders role-default style chains a -> b -> c" do
    playbook = File.tempname("unsafe-safe", ".yml")
    File.write(playbook, <<-YAML)
      - name: safe templating
        hosts: all
        gather_facts: false
        vars:
          a: "{{ b }}"
          b: "hello-{{ c }}"
          c: world
        tasks:
          - name: render chain
            ansible.builtin.set_fact:
              y: "{{ a }}-suffix"
          - name: show
            ansible.builtin.debug: var=y
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    output.to_s.should contain("hello-world-suffix")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "renders loop items that are author-defined template strings" do
    playbook = File.tempname("unsafe-safe-loop", ".yml")
    File.write(playbook, <<-YAML)
      - name: safe loop items
        hosts: all
        gather_facts: false
        vars:
          names: ["{{ a }}", "plain"]
          a: world
        tasks:
          - name: loop
            ansible.builtin.debug: msg="item={{ item }}"
            loop: "{{ names }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    output.to_s.should contain("item=world")
    output.to_s.should contain("item=plain")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
