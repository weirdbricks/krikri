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

# Runs *tasks* under a `gather_facts: true` play in a temp playbook dir
# that ships vars/Debian.yml and vars/RedHat.yml (whichever matches the
# spec host's real ansible_os_family is the one include_vars loads).
# Returns {status, output}. This is the shape the 2026-09 loop-alias
# over-taint regression broke: a loop LIST of author template strings that
# REFERENCE facts must still be rendered - the author's template text is
# trusted, only the fact VALUES it pulls in are data.
private def fact_loop_run(tasks : String) : {Process::Status, String}
  dir = File.tempname("unsafe-loop-facts")
  Dir.mkdir(dir)
  Dir.mkdir(File.join(dir, "vars"))
  File.write(File.join(dir, "vars", "Debian.yml"), "loop_loaded: from-debian-vars\n")
  File.write(File.join(dir, "vars", "RedHat.yml"), "loop_loaded: from-redhat-vars\n")
  File.write(File.join(dir, "vars", "default.yml"), "loop_loaded: from-default-vars\n")
  playbook = File.join(dir, "site.yml")
  File.open(playbook, "w") do |file|
    file.puts "- name: loop fact templates"
    file.puts "  hosts: all"
    file.puts "  gather_facts: true"
    file.puts "  tasks:"
    tasks.each_line do |line|
      file.puts line.empty? ? "" : "    " + line
    end
  end

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "loop items that are author template strings referencing facts still render" do
  # Regression shape 1 (PowerDNS.pdns): a literal loop list whose elements
  # are templates over gathered facts, guarded by a fileglob `when:` that
  # itself references `item`. The over-taint left every item verbatim
  # unrendered (`skipping: ... (item={{ ansible_os_family }}.yml)`), so
  # the vars file was never loaded and the role failed with
  # "'default_pdns_package_name' is undefined". Real Ansible renders the
  # items (item=Debian.yml) and loads the file.
  it "renders a literal loop list of fact templates and loads the matching vars file (pdns shape)" do
    status, output = fact_loop_run(<<-YAML)
      - name: load os vars
        ansible.builtin.include_vars: "{{ item }}"
        loop:
          - "{{ playbook_dir }}/vars/{{ ansible_os_family }}.yml"
          - "{{ playbook_dir }}/vars/{{ ansible_distribution }}.yml"
        when: lookup('ansible.builtin.fileglob', item, wantlist=True) | length > 0
      - name: show loaded var
        ansible.builtin.debug:
          msg: "loop_loaded={{ loop_loaded | default('UNDEFINED') }}"
      YAML
    status.success?.should be_true, output
    output.should match(/loop_loaded=from-(debian|redhat)-vars/), output
    output.should_not contain("UNDEFINED"), output
    # The regression's tell: unrendered item labels.
    output.should_not contain("(item={{"), output
  end

  # Regression shape 2 (linux-system-roles.metrics/.logging): the whole
  # list was tainted, so even the plain `default.yml` item stayed
  # unrendered.
  it "renders every item of a fact-template loop list, plain entries included (lsr shape)" do
    status, output = fact_loop_run(<<-YAML)
      - name: load os vars
        ansible.builtin.include_vars: "{{ item }}"
        loop:
          - "{{ playbook_dir }}/vars/default.yml"
          - "{{ playbook_dir }}/vars/{{ ansible_facts['os_family'] }}.yml"
      - name: show loaded var
        ansible.builtin.debug:
          msg: "loop_loaded={{ loop_loaded | default('UNDEFINED') }}"
      YAML
    status.success?.should be_true, output
    output.should match(/loop_loaded=from-(debian|redhat)-vars/), output
    output.should_not contain("UNDEFINED"), output
    output.should_not contain("(item={{"), output
  end

  # Regression shape 3 (willshersystems.sshd): with_first_found whose
  # files/paths are author templates over facts found nothing (templates
  # unrendered) where real Ansible loads the first existing candidate.
  it "renders with_first_found files/paths over facts and loads the found vars file (sshd shape)" do
    status, output = fact_loop_run(<<-YAML)
      - name: load os vars
        ansible.builtin.include_vars: "{{ item }}"
        with_first_found:
          - files:
              - "{{ ansible_facts['distribution'] }}_{{ ansible_facts['distribution_major_version'] }}.yml"
              - "{{ ansible_facts['os_family'] }}.yml"
            paths:
              - "{{ playbook_dir }}/vars"
            skip: true
      - name: show loaded var
        ansible.builtin.debug:
          msg: "loop_loaded={{ loop_loaded | default('UNDEFINED') }}"
      YAML
    status.success?.should be_true, output
    output.should match(/loop_loaded=from-(debian|redhat)-vars/), output
    output.should_not contain("UNDEFINED"), output
    output.should_not contain("(item={{"), output
  end

  # Hostile content flowing INTO a rendered author item must stay
  # verbatim: the item's template text is trusted and rendered, but the
  # register value it embeds is data - the derived item text must never
  # itself be re-rendered as template (taint follows the data).
  it "renders an author item embedding hostile register data without executing it" do
    canary = File.tempname("unsafe-derived-item-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="item={{ item }}"
        loop:
          - "{{ r.stdout }}-suffix"
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a derived loop item:\n#{output}"
    output.to_s.should contain("#{canary_text(canary)}-suffix")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end
end

describe "loop items from author template sources over set_fact/register data always render" do
  # The 2026-09 with_items-taint regression (geerlingguy.php's
  # "Ensure configuration directories exist."): each ELEMENT of a literal
  # loop list that is a single-span direct reference to a resolved name
  # (`"{{ paths | flatten }}"`, `"{{ r.stdout }}"`) was treated as a taint
  # source, the `item` alias got tainted, and the taint then SKIPPED THE
  # FIRST RENDER of the item - every element printed verbatim
  # (`item={{ paths | flatten }}`), no directories were ever created, and
  # buluma.phpmyadmin broke downstream. Taint must only ever prevent
  # RE-rendering of values that came from unsafe data; the author-written
  # template text is always rendered exactly once, and only the VALUES
  # the render produces are marked (value-level, via the UnsafeValues
  # registry) so they are never re-rendered.
  it "renders with_items elements that are direct references to set_fact/register data (geerlingguy.php shape)" do
    canary = File.tempname("unsafe-items-render-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: set paths
        ansible.builtin.set_fact:
          paths: ["/a/1", "/a/2"]
      - name: consume
        ansible.builtin.debug: msg="item={{ item }}"
        with_items:
          - "{{ paths | flatten }}"
          - "{{ r.stdout }}"
      YAML
    status.success?.should be_true, output.to_s
    # The set_fact-sourced elements render AND flatten one level.
    output.to_s.should contain("item=/a/1")
    output.to_s.should contain("item=/a/2")
    # The register-sourced element renders to the (hostile) value.
    output.to_s.should contain("item=#{canary_text(canary)}")
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a with_items element:\n#{output}"
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "renders loop: string-form and array-literal sources over set_fact data" do
    canary = File.tempname("unsafe-strform-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: set facts
        ansible.builtin.set_fact:
          paths: ["/a/1", "/a/2"]
          first: alpha
          second: beta
      - name: string form
        ansible.builtin.debug: msg="item={{ item }}"
        loop: "{{ paths }}"
      - name: array literal
        ansible.builtin.debug: msg="item={{ item }}"
        loop: "{{ [first, second] }}"
      YAML
    status.success?.should be_true, output.to_s
    output.to_s.should contain("item=/a/1")
    output.to_s.should contain("item=/a/2")
    output.to_s.should contain("item=alpha")
    output.to_s.should contain("item=beta")
    output.to_s.should_not contain("(item={{"), output.to_s
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  # Hostile variants of every shape above: the item VALUES derive from
  # unsafe data, so they print verbatim and never execute - the value is
  # marked in the UnsafeValues registry exactly where the retired `item`
  # name taint used to protect it, but never at the cost of the first
  # render.
  it "prints hostile with_dict items verbatim without executing them" do
    canary = File.tempname("unsafe-dict-item-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: set hostile dict
        ansible.builtin.set_fact:
          hd: {"k": "{{ r.stdout }}"}
      - name: consume
        ansible.builtin.debug: msg="item={{ item.value }}"
        with_dict: "{{ hd }}"
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a with_dict item:\n#{output}"
    output.to_s.should contain(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "prints hostile items of a list-literal loop expression verbatim without executing them" do
    canary = File.tempname("unsafe-arrlit-item-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="item={{ item }}"
        loop: "{{ [r.stdout] }}"
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a list-literal loop item:\n#{output}"
    output.to_s.should contain("item=#{canary_text(canary)}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "prints a hostile scalar with_items source's single wrapped item verbatim without executing it" do
    canary = File.tempname("unsafe-scalar-wrap-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="item={{ item }}"
        with_items: "{{ r.stdout }}"
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a scalar-wrapped with_items item:\n#{output}"
    output.to_s.should contain("item=#{canary_text(canary)}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "prints hostile with_nested and with_subelements items verbatim without executing them" do
    canary = File.tempname("unsafe-nested-subelem-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: set hostile subs
        ansible.builtin.set_fact:
          subs: [{"name": "s1", "kids": ["{{ r.stdout }}"]}]
      - name: nested consume
        ansible.builtin.debug: msg="item={{ item.0 }}-{{ item.1 }}"
        with_nested:
          - "{{ r.stdout_lines }}"
          - [X]
      - name: subelements consume
        ansible.builtin.debug: msg="item={{ item.1 }}"
        with_subelements:
          - "{{ subs }}"
          - kids
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a with_nested/with_subelements item:\n#{output}"
    output.to_s.should contain("#{canary_text(canary)}-X")
    output.to_s.should_not contain("(item={{"), output.to_s
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "prints a hostile custom loop_var's item verbatim without executing it" do
    canary = File.tempname("unsafe-loopvar-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run(<<-YAML, canary: canary)
      - name: consume
        ansible.builtin.debug: msg="item={{ p }}"
        loop: "{{ r.stdout_lines }}"
        loop_control:
          loop_var: p
      YAML
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a custom loop_var item:\n#{output}"
    output.to_s.should contain("item=#{canary_text(canary)}")
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

describe "a handler's register: result is execution data too" do
  # The handler dispatch path stores its register: through the SAME
  # register_result the regular-task path uses, so the hostile text must
  # stay verbatim through a flush and through every downstream consumer -
  # including a set_fact COPY of it (a set_fact derived from handler-
  # registered data is execution data exactly like one derived from a
  # task-registered result).
  it "never re-renders a hostile handler register via a later set_fact + when: + debug" do
    canary = File.tempname("unsafe-handler-reg-canary")
    File.delete(canary) if File.exists?(canary)
    playbook = File.tempname("unsafe-handler-reg", ".yml")
    File.write(playbook, <<-YAML)
      - name: unsafe handler register repro
        hosts: localhost
        gather_facts: false
        handlers:
          - name: produce hostile output
            ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}"
            register: r
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            notify: produce hostile output
          - name: flush
            ansible.builtin.meta: flush_handlers
          - name: copy into a fact
            ansible.builtin.set_fact:
              copy: "{{ r.stdout }}"
          - name: consume via a condition and debug
            ansible.builtin.debug:
              msg: "saw {{ copy }}"
            when: copy is defined
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.should be_true, output.to_s
    File.exists?(canary).should be_false,
      "hostile lookup EXECUTED on the controller via a handler register:\n#{output}"
    output.to_s.should contain(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
