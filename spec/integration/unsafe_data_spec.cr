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

# The hostile text a producer task's registered result carries - exactly
# the string whose re-render would touch *canary*.
private def canary_text(canary : String) : String
  "{{ lookup('pipe', 'touch #{canary}') }}"
end

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

  it "recursively renders author template chains inside a .j2 template file" do
    # The template: action plugin pre-renders the whole vars scope before
    # the engine renders the .j2 file (prepare_template_vars_json) - the
    # fix that stopped it re-rendering hostile module results must not
    # stop it rendering AUTHOR-defined chains: a role default whose value
    # is `{{ other_var }}` must still resolve inside a .j2 template, and
    # an extra-var must still reach it.
    playbook = File.tempname("unsafe-safe-tmpl", ".yml")
    template = File.tempname("unsafe-safe-chain", ".j2")
    dest = File.tempname("unsafe-safe-out")
    File.write(template, "{{ a }}|{{ motd }}")
    File.write(playbook, <<-YAML)
      - name: safe template file
        hosts: all
        gather_facts: false
        vars:
          a: "{{ b }}"
          b: "hello-{{ c }}"
          c: world
        tasks:
          - name: render the template file
            ansible.builtin.template:
              src: #{template}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "-e", "motd=EXTRA", playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    File.read(dest).strip.should eq("hello-world|EXTRA")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(template) if template && File.exists?(template)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

# The template: module path - a producer task registers a hostile module
# result, then a `template:` task renders a .j2 file against the full
# scope. Runs *template_body* as the .j2 source and returns
# {status, output, dest path, canary path}; caller deletes dest/canary.
private def template_repro(template_body : String)
  canary = File.tempname("unsafe-tmpl-canary")
  File.delete(canary) if File.exists?(canary)
  src = File.tempname("unsafe-tmpl-src", ".j2")
  dest = File.tempname("unsafe-tmpl-dest")
  File.write(src, template_body)
  playbook = File.tempname("unsafe-tmpl", ".yml")
  File.open(playbook, "w") do |file|
    file.puts "- name: template unsafe repro"
    file.puts "  hosts: all"
    file.puts "  gather_facts: false"
    file.puts "  tasks:"
    file.puts "    - name: produce hostile output"
    file.puts %(      ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}")
    file.puts "      register: r"
    file.puts "    - name: consume"
    file.puts "      ansible.builtin.template:"
    file.puts %(        src: #{src})
    file.puts %(        dest: #{dest})
  end

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, dest, canary}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(src) if src && File.exists?(src)
end

describe "template: module never re-renders hostile data" do
  it "writes a direct {{ r.stdout }} reference verbatim" do
    status, output, dest, canary = template_repro("{{ r.stdout }}")
    status.success?.should be_true, output
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via template: vars preparation:\n#{output}"
    File.read(dest).should contain(canary_text(canary))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "writes a {{ r.stdout | trim }} reference verbatim (transformed unsafe text)" do
    status, output, dest, canary = template_repro("{{ r.stdout | trim }}")
    status.success?.should be_true, output
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via template: vars preparation:\n#{output}"
    File.read(dest).should contain(canary_text(canary))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "renders a {% include %} sub-template's hostile reference verbatim" do
    sub = File.tempname("unsafe-inc-sub", ".j2")
    File.write(sub, "{{ r.stdout }}")
    status, output, dest, canary = template_repro(%({% include "#{sub}" %}))
    status.success?.should be_true, output
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a template include:\n#{output}"
    File.read(dest).should contain(canary_text(canary))
  ensure
    File.delete(sub) if sub && File.exists?(sub)
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "never re-renders hostile data through lookup('template', ...) in a debug msg" do
    canary = File.tempname("unsafe-lk-canary")
    File.delete(canary) if File.exists?(canary)
    src = File.tempname("unsafe-lk-src", ".j2")
    File.write(src, "{{ r.stdout }}")
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug:
          msg: "{{ lookup('template', '#{src}') }}"
      YAML
    status.success?.should be_true, output
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via the template lookup:\n#{output}"
    output.to_s.should contain(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(src) if src && File.exists?(src)
  end

  it "never re-renders hostile items from a hostvars-rooted loop source" do
    canary = File.tempname("unsafe-hv-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="{{ item }}"
        loop: "{{ hostvars[inventory_hostname].r.stdout_lines }}"
      YAML
    status.success?.should be_true, output
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a hostvars-rooted loop:\n#{output}"
    output.to_s.should contain(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end
end

describe "async debug var= is gated in its detached plugin process" do
  # An `async:` debug task runs plugins/debug.cr in a DETACHED process
  # (`krikri-playbook __async_run`, or the uploaded binary on a remote
  # target) whose own unsafe registries start empty - without the
  # serialized registry snapshot in the plugin config, that process's
  # re-render gates were blind. The var= path there also now renders
  # lazy author templates exactly like the action plugin does.
  it "prints a hostile var verbatim without executing it (via a lazy author template)" do
    canary = File.tempname("unsafe-async-canary")
    File.delete(canary) if File.exists?(canary)
    playbook = File.tempname("unsafe-async", ".yml")
    File.write(playbook, <<-YAML)
      - name: async unsafe repro
        hosts: all
        gather_facts: false
        vars:
          x: "{{ r.stdout }}"
        tasks:
          - name: produce hostile output
            ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}"
            register: r
          - name: consume
            ansible.builtin.debug: var=x
            async: 10
            poll: 2
            register: a
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED in the detached async plugin process:\n#{output}"
    output.to_s.should contain(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still renders a lazy author template in the detached process" do
    playbook = File.tempname("unsafe-async-safe", ".yml")
    File.write(playbook, <<-YAML)
      - name: async safe repro
        hosts: all
        gather_facts: false
        vars:
          x: "{{ greeting }}-suffix"
          greeting: hello
        tasks:
          - name: consume
            ansible.builtin.debug: var=x
            async: 10
            poll: 2
            register: a
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    output.to_s.should contain("hello-suffix")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
