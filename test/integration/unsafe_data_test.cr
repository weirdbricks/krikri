require "../minitest_helper"
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
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-two-local-hosts.ini")

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

# crystal spec registered these `it`s from a runtime helper method;
# minitest registers tests at compile time, so this is a macro that
# stamps out one named test per call site (same bodies, same labels).
macro assert_not_executed(playbook_body, label)
  {% name = "never re-renders a hostile module result via " + label.id.stringify %}
  it {{ name.stringify }} do
    label_text = {{ label }}
    canary = File.tempname("unsafe-canary")
    File.delete(canary) if File.exists?(canary)
    status, output = hostile_run({{ playbook_body }}, canary: canary)
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via #{label_text}:\n#{output}")
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
    status.success?.must_equal(true, output)
    output.must_match(/loop_loaded=from-(debian|redhat)-vars/, output)
    output.wont_include("UNDEFINED", output)
    # The regression's tell: unrendered item labels.
    output.wont_include("(item={{", output)
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
    status.success?.must_equal(true, output)
    output.must_match(/loop_loaded=from-(debian|redhat)-vars/, output)
    output.wont_include("UNDEFINED", output)
    output.wont_include("(item={{", output)
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
    status.success?.must_equal(true, output)
    output.must_match(/loop_loaded=from-(debian|redhat)-vars/, output)
    output.wont_include("UNDEFINED", output)
    output.wont_include("(item={{", output)
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a derived loop item:\n#{output}")
    output.to_s.must_include("#{canary_text(canary)}-suffix")
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
    status.success?.must_equal(true, output.to_s)
    # The set_fact-sourced elements render AND flatten one level.
    output.to_s.must_include("item=/a/1")
    output.to_s.must_include("item=/a/2")
    # The register-sourced element renders to the (hostile) value.
    output.to_s.must_include("item=#{canary_text(canary)}")
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a with_items element:\n#{output}")
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
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("item=/a/1")
    output.to_s.must_include("item=/a/2")
    output.to_s.must_include("item=alpha")
    output.to_s.must_include("item=beta")
    output.to_s.wont_include("(item={{", output.to_s)
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a with_dict item:\n#{output}")
    output.to_s.must_include(canary_text(canary))
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a list-literal loop item:\n#{output}")
    output.to_s.must_include("item=#{canary_text(canary)}")
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a scalar-wrapped with_items item:\n#{output}")
    output.to_s.must_include("item=#{canary_text(canary)}")
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a with_nested/with_subelements item:\n#{output}")
    output.to_s.must_include("#{canary_text(canary)}-X")
    output.to_s.wont_include("(item={{", output.to_s)
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a custom loop_var item:\n#{output}")
    output.to_s.must_include("item=#{canary_text(canary)}")
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
    status.success?.must_equal(true, output.to_s)
    # Real ansible-core prints the unsafe text verbatim - the braces must
    # still be there, not rendered away.
    output.to_s.must_include("{{ lookup('pipe', 'touch #{canary}') }}")
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
    status.success?.must_equal(false, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a failing loop source:\n#{output}")
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via gathered facts:\n#{output}")
    output.to_s.must_include("{{ lookup('pipe', 'touch #{canary}') }}")
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "an !unsafe value was templated (lookup executed):\n#{output}")
    output.to_s.must_include("{{ lookup('pipe', 'touch #{canary}') }}")
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
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("hello-world-suffix")
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
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("item=world")
    output.to_s.must_include("item=plain")
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
    status.success?.must_equal(true, output.to_s)
    File.read(dest).strip.must_equal("hello-world|EXTRA")
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
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via template: vars preparation:\n#{output}")
    File.read(dest).must_include(canary_text(canary))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "writes a {{ r.stdout | trim }} reference verbatim (transformed unsafe text)" do
    status, output, dest, canary = template_repro("{{ r.stdout | trim }}")
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via template: vars preparation:\n#{output}")
    File.read(dest).must_include(canary_text(canary))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "renders a {% include %} sub-template's hostile reference verbatim" do
    sub = File.tempname("unsafe-inc-sub", ".j2")
    File.write(sub, "{{ r.stdout }}")
    status, output, dest, canary = template_repro(%({% include "#{sub}" %}))
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a template include:\n#{output}")
    File.read(dest).must_include(canary_text(canary))
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
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via the template lookup:\n#{output}")
    output.to_s.must_include(canary_text(canary))
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
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a hostvars-rooted loop:\n#{output}")
    output.to_s.must_include(canary_text(canary))
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED in the detached async plugin process:\n#{output}")
    output.to_s.must_include(canary_text(canary))
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
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("hello-suffix")
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
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a handler register:\n#{output}")
    output.to_s.must_include(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# ---------------------------------------------------------------------------
# Full hostile-container matrix: hostile data (a module result whose text is
# itself a `{{ lookup('pipe', ...) }}` template) held by a task-level var,
# a block var, a role var, or an include_role var, in every container shape
# (scalar, list, dict, nested list-of-dict, dict-of-list), consumed directly,
# through filters, in `when:`, in `loop:`, in module args, in `template:`,
# and through a set_fact copy. Every case gets its own canary file the
# hostile lookup would create if the controller ever rendered the data as
# template text; every expectation below was verified live against real
# ansible-playbook (2.19) so the assertions pin parity, not just safety.
# ---------------------------------------------------------------------------
private MATRIX_SHAPES    = %w(scalar list dict list_of_dict dict_of_list)
private MATRIX_CONSUMERS = %w(direct var f_list f_first f_join f_to_json
  f_dict2items when loop args template setfact)

private record MatrixCase, index : Int32, shape : String, kind : String, consumer : String
private record MatrixRun, dir : String, status : Process::Status,
  output : String, sections : Hash(String, String)

private def matrix_kind(shape : String) : String
  case shape
  when "scalar", "list" then shape
  when "list_of_dict"   then "list"
  else                       "dict"
  end
end

private def matrix_allowed?(kind : String, consumer : String) : Bool
  case consumer
  when "f_dict2items" then kind == "dict"
  when "f_first"      then kind == "list"
  when "f_join"       then kind == "list" || kind == "dict"
  else                     true
  end
end

private def matrix_cases : Array(MatrixCase)
  cases = [] of MatrixCase
  i = 0
  MATRIX_SHAPES.each do |shape|
    kind = matrix_kind(shape)
    MATRIX_CONSUMERS.each do |consumer|
      next unless matrix_allowed?(kind, consumer)
      cases << MatrixCase.new(i, shape, kind, consumer)
      i += 1
    end
  end
  cases
end

# The var definition for one case: an expression over that case's own
# registered result, so the hostile text carries the case's own canary.
private def matrix_shape_expr(shape : String, reg : String) : String
  case shape
  when "scalar"       then "{{ #{reg}.stdout }}"
  when "list"         then "{{ #{reg}.stdout_lines }}"
  when "dict"         then "{{ {'a': #{reg}.stdout} }}"
  when "list_of_dict" then "{{ [{'a': #{reg}.stdout}] }}"
  when "dict_of_list" then "{{ {'a': #{reg}.stdout_lines} }}"
  else                     raise "unknown shape #{shape}"
  end
end

private def matrix_consumer_task_lines(mc : MatrixCase, dir : String, var_expr : String?) : Array(String)
  v = "b#{mc.index}"
  lines =
    case mc.consumer
    when "direct"
      ["- name: c#{mc.index}_direct",
       "  ansible.builtin.debug:",
       "    msg: \"{{ #{v} }}\""]
    when "var"
      ["- name: c#{mc.index}_var",
       "  ansible.builtin.debug: var=#{v}"]
    when .starts_with?("f_")
      ["- name: c#{mc.index}_#{mc.consumer}",
       "  ansible.builtin.debug:",
       "    msg: \"{{ #{v} | #{mc.consumer[2..]} }}\""]
    when "when"
      ["- name: c#{mc.index}_when",
       "  ansible.builtin.debug:",
       "    msg: when-ran",
       "  when: #{v} | length > 0"]
    when "loop"
      ["- name: c#{mc.index}_loop",
       "  ansible.builtin.debug:",
       "    msg: \"{{ item }}\"",
       "  loop: \"{{ #{v} }}\""]
    when "args"
      ["- name: c#{mc.index}_args",
       "  ansible.builtin.command: echo \"{{ #{v} }}\"",
       "  register: ca#{mc.index}",
       "- name: c#{mc.index}_args_show",
       "  ansible.builtin.debug:",
       "    msg: \"{{ ca#{mc.index}.stdout }}\""]
    when "template"
      ["- name: c#{mc.index}_template",
       "  ansible.builtin.template:",
       "    src: t#{mc.index}.j2",
       "    dest: #{dir}/dest#{mc.index}.txt",
       "- name: c#{mc.index}_tmpl_show",
       "  ansible.builtin.command: cat #{dir}/dest#{mc.index}.txt",
       "  register: ct#{mc.index}",
       "- name: c#{mc.index}_tmpl_show2",
       "  ansible.builtin.debug:",
       "    msg: \"{{ ct#{mc.index}.stdout }}\""]
    when "setfact"
      ["- name: c#{mc.index}_setfact",
       "  ansible.builtin.set_fact:",
       "    sf#{mc.index}: \"{{ #{v} }}\"",
       "- name: c#{mc.index}_setfact_show",
       "  ansible.builtin.debug:",
       "    msg: \"{{ sf#{mc.index} }}\""]
    else
      raise "unknown consumer #{mc.consumer}"
    end
  # ignore_errors (and the task-scope var definition) attach to the case's
  # FIRST task - the one that consumes the hostile var - so one failing case
  # (a loop source that legitimately fails, exactly like real Ansible) doesn't
  # stop the remaining cases from running, and multi-task cases (args/
  # template/setfact show tasks) don't inherit the var definition.
  second_task = lines.index { |line| line.starts_with?("- name:") && line != lines[0] } || lines.size
  opts = ["  ignore_errors: true"]
  if var_expr
    opts << "  vars:"
    opts << "    b#{mc.index}: \"#{var_expr}\""
  end
  opts.each_with_index { |opt, offset| lines.insert(second_task + offset, opt) }
  lines
end

private def matrix_producer_lines(mc : MatrixCase, canary : String) : Array(String)
  ["- name: p#{mc.index}",
   "  ansible.builtin.command: echo \"{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}\"",
   "  register: r#{mc.index}"]
end

# Section expectations, verified live against real ansible-playbook:
# - most cases print the hostile text verbatim (real Ansible's unsafe-data
#   passthrough) - assert the canary path appears in the task's output;
# - `when:` only proves the condition evaluated ("when-ran");
# - a scalar/dict/dict-of-list `loop:` source FAILS in real Ansible too
#   ("must resolve to a 'list'") - assert the same failure message;
# - a scalar through `| list` is split into single-char strings (real
#   Ansible does the same to a string);
# - a dict through `| list`/`| join` yields only the KEY ("a") - the
#   hostile VALUE must not even surface in the output.
private def matrix_expectation(shape : String, consumer : String, canary : String) : {String, String}
  hostile = "touch #{canary}"
  case consumer
  when "when"
    {"when-ran", ""}
  when "loop"
    case shape
    when "scalar"               then {"not 'str'", ""}
    when "dict", "dict_of_list" then {"not 'dict'", ""}
    else                             {hostile, ""}
    end
  when "f_list"
    case shape
    when "scalar"               then {"\"t\",\"o\",\"u\",\"c\",\"h\"", ""}
    when "dict", "dict_of_list" then {"[\"a\"]", hostile}
    else                             {hostile, ""}
    end
  when "f_join"
    case shape
    when "dict", "dict_of_list" then {"a", hostile}
    else                             {hostile, ""}
    end
  else
    {hostile, ""}
  end
end

private def matrix_section(run : MatrixRun, name : String) : String?
  return run.sections[name]? if run.sections.has_key?(name)
  # role tasks are reported with the role-name prefix ("mvar : c0_direct")
  run.sections.each_key do |key|
    return run.sections[key] if key.ends_with?(name)
  end
  nil
end

private MATRIX_RUNS = {} of String => MatrixRun

private def matrix_sections(output : String) : Hash(String, String)
  sections = Hash(String, String).new("")
  current = nil
  output.each_line do |line|
    if line.starts_with?("TASK [") && (close = line.index(']'))
      current = line[6...close]
      sections[current.not_nil!] = ""
    elsif line.starts_with?("PLAY [") || line.starts_with?("PLAY RECAP")
      current = nil
    elsif cur = current
      sections[cur] += line + "\n"
    end
  end
  sections
end

private def matrix_run(scope : String) : MatrixRun
  MATRIX_RUNS[scope] ||= begin
    dir = File.tempname("unsafe-matrix-#{scope}")
    Dir.mkdir(dir)
    at_exit { FileUtils.rm_rf(dir) unless ENV["KEEP_MATRIX"]? }
    cases = matrix_cases
    play_tasks = [] of String
    role_tasks = [] of String
    role_vars = [] of String
    include_vars = [] of String

    cases.each do |case_row|
      canary = File.join(dir, "PWNED_#{scope}_#{case_row.shape}_#{case_row.consumer}")
      expr = matrix_shape_expr(case_row.shape, "r#{case_row.index}")
      producer = matrix_producer_lines(case_row, canary)
      consumer = matrix_consumer_task_lines(case_row, dir, scope == "task" ? expr : nil)
      case scope
      when "task"
        play_tasks.concat(producer.map { |line| "    " + line })
        play_tasks.concat(consumer.map { |line| "    " + line })
      when "block"
        block = ["- name: blk#{case_row.index}",
                 "  vars:",
                 "    b#{case_row.index}: \"#{expr}\"",
                 "  block:"]
        block.concat(consumer.map { |line| "    " + line })
        play_tasks.concat(producer.map { |line| "    " + line })
        play_tasks.concat(block.map { |line| "    " + line })
      when "role"
        role_vars << "b#{case_row.index}: \"#{expr}\""
        role_tasks.concat(consumer.map { |line| "  " + line })
        play_tasks.concat(producer.map { |line| "    " + line })
      when "include_role"
        include_vars << "        b#{case_row.index}: \"#{expr}\""
        role_tasks.concat(consumer.map { |line| "  " + line })
        play_tasks.concat(producer.map { |line| "    " + line })
      end
    end

    role_base = ""
    if scope == "role"
      role_base = File.join(dir, "roles", "mvar")
      Dir.mkdir_p(File.join(role_base, "tasks"))
      Dir.mkdir_p(File.join(role_base, "vars"))
      Dir.mkdir_p(File.join(role_base, "templates"))
      File.write(File.join(role_base, "vars", "main.yml"), role_vars.join("\n") + "\n")
      File.write(File.join(role_base, "tasks", "main.yml"), role_tasks.join("\n") + "\n")
    elsif scope == "include_role"
      role_base = File.join(dir, "roles", "mvar2")
      Dir.mkdir_p(File.join(role_base, "tasks"))
      Dir.mkdir_p(File.join(role_base, "templates"))
      File.write(File.join(role_base, "tasks", "main.yml"), role_tasks.join("\n") + "\n")
    end

    # template sources: each case's .j2 simply interpolates its var
    cases.each do |case_row|
      base = scope.in?("task", "block") ? dir : role_base
      File.write(File.join(base, "t#{case_row.index}.j2"), "{{ b#{case_row.index} }}\n")
    end

    playbook_lines =
      if scope == "role"
        ["- name: hostile matrix role",
         "  hosts: all",
         "  gather_facts: false",
         "  pre_tasks:"] + play_tasks + ["  roles:", "    - role: mvar"]
      else
        head = ["- name: hostile matrix #{scope}",
                "  hosts: all",
                "  gather_facts: false",
                "  tasks:"] + play_tasks
        if scope == "include_role"
          head + ["    - name: include role",
                  "      ansible.builtin.include_role:",
                  "        name: mvar2",
                  "      vars:"] + include_vars
        else
          head
        end
      end
    playbook = File.join(dir, "site.yml")
    File.write(playbook, playbook_lines.join("\n") + "\n")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    MatrixRun.new(dir, status, output.to_s, matrix_sections(output.to_s))
  end
end

# crystal spec built these describes/tests with runtime `.each` loops;
# minitest registers tests at compile time, so the same (index, shape,
# kind, consumer) matrix - with the same matrix_allowed? filter and
# index order as matrix_cases - is unrolled with macro loops instead.
{% for scope_pair in [{"task", "task-level vars"}, {"block", "block vars"}, {"role", "role vars"}, {"include_role", "include_role vars"}] %}
  {% scope = scope_pair[0] %}
  {% label = scope_pair[1] %}
  describe "hostile containers in {{ label.id }} are never re-rendered (full matrix vs real-Ansible-verified output)" do
    it "runs the {{ scope.id }}-scope matrix playbook successfully" do
      run = matrix_run({{ scope }})
      run.status.success?.must_equal(true, run.output)
    end

    {% i = 0 %}
    {% for shape in %w(scalar list dict list_of_dict dict_of_list) %}
      {% kind = shape == "scalar" ? "scalar" : shape == "list" ? "list" : shape == "dict" ? "dict" : shape == "list_of_dict" ? "list" : "dict" %}
      {% for consumer in %w(direct var f_list f_first f_join f_to_json f_dict2items when loop args template setfact) %}
        {% allowed = consumer == "f_dict2items" ? (kind == "dict") : consumer == "f_first" ? (kind == "list") : consumer == "f_join" ? (kind == "list" || kind == "dict") : true %}
        {% if allowed %}
          {% index = i %}
          {% i = i + 1 %}
          it "{{ shape.id }} var via {{ consumer.id }}: no canary file is created and the output matches real Ansible" do
            run = matrix_run({{ scope }})
            canary = File.join(run.dir, "PWNED_{{ scope.id }}_{{ shape.id }}_{{ consumer.id }}")
            File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller ({{ scope.id }} var, {{ shape.id }}, {{ consumer.id }}):\n#{run.output}")

            section_name =
              case {{ consumer }}
              when "args"     then "c{{ index }}_args_show"
              when "template" then "c{{ index }}_tmpl_show2"
              when "setfact"  then "c{{ index }}_setfact_show"
              else                 "c{{ index }}_{{ consumer.id }}"
              end
            section = matrix_section(run, section_name)
            section.wont_be_nil("missing output section #{section_name}\n#{run.output}")

            must_contain, must_not_contain = matrix_expectation({{ shape }}, {{ consumer }}, canary)
            section.not_nil!.must_include(must_contain,
              "expected real-Ansible output for {{ shape.id }}/{{ consumer.id }} missing:\n#{section}")
            unless must_not_contain.empty?
              section.not_nil!.wont_include(must_not_contain,
                "hostile value surfaced in a keys-only {{ consumer.id }} result:\n#{section}")
            end
          end
        {% end %}
      {% end %}
    {% end %}
  end
{% end %}

describe "cross-host hostvars reads never re-render another host's execution data" do
  # The producer host writes in play 1 and NEVER EXECUTES AGAIN: play 2
  # targets only the reading host, so the producer's per-task context
  # build - which is where the per-host unsafe-name registry and the
  # value-level text registry used to get populated - never runs for it.
  # hostvars[<producer>] hands its registered result / set_fact value to
  # the reading host, whose re-render funnels must consult the OWNING
  # host's registry: registered results and set_facts are execution data
  # on every host, verbatim forever (real ansible-core's AnsibleUnsafe).
  # Before the write-time marking + per-host origin gate, the hostile
  # lookup executed on the controller through the reading host's span
  # re-pass.
  it "never re-renders a producer host's registered result / set_fact read via hostvars" do
    canary = File.tempname("unsafe-hv-cross-canary")
    File.delete(canary) if File.exists?(canary)
    playbook = File.tempname("unsafe-hv-cross", ".yml")
    File.open(playbook, "w") do |file|
      file.puts "- name: produce hostile output on one host only"
      file.puts "  hosts: hosttwo"
      file.puts "  gather_facts: false"
      file.puts "  tasks:"
      file.puts "    - name: produce"
      file.puts %(      ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}")
      file.puts "      register: r"
      file.puts "    - name: copy into a set_fact"
      file.puts "      ansible.builtin.set_fact:"
      file.puts %(        hostile_fact: "{{ r.stdout }}")
      file.puts "- name: consume on the OTHER host - the producer never executes again"
      file.puts "  hosts: hostone"
      file.puts "  gather_facts: false"
      file.puts "  tasks:"
      file.puts "    - name: consume"
      file.puts %(      ansible.builtin.debug: msg="fact={{ hostvars['hosttwo'].hostile_fact }}")
    end

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "hostile lookup EXECUTED on the controller via a cross-host hostvars read:\n#{output}")
    output.to_s.must_include(canary_text(canary))
  ensure
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# Real ansible-core's taint is a TYPE: `r.stdout | trim` of padded
# hostile stdout is still AnsibleUnsafeText, so it is never re-rendered
# even after it is flattened into a loop item under a name no gate
# knows. The exact-text registry alone could not see such a derived
# string (the transform dropped the registered whitespace), and
# `loop: ["look-{{ relay }}-ma"]` consumed by `"x-{{ item }}-y"`
# executed the controller `lookup('pipe', ...)`. Live-verified against
# real ansible-playbook 2.19, which prints the item verbatim. Runs the
# relay shape with *filter* applied to registered (optionally padded)
# hostile stdout and returns {status, output}.
private def derived_relay_run(filter : String, *, canary : String, padded : Bool)
  playbook = File.tempname("unsafe-derived", ".yml")
  File.open(playbook, "w") do |file|
    file.puts "- name: derived-taint relay"
    file.puts "  hosts: all"
    file.puts "  gather_facts: false"
    file.puts "  vars:"
    file.puts "    relay: \"{{ r.stdout | #{filter} }}\""
    file.puts "  tasks:"
    file.puts "    - name: produce hostile output"
    padding = padded ? " " : ""
    file.puts %(      ansible.builtin.command: echo "#{padding}{{ '{{' }} lookup('pipe', 'touch #{canary}') {{ '}}' }}#{padding}")
    file.puts "      register: r"
    file.puts "    - name: flatten the derivative into a loop item"
    file.puts "      ansible.builtin.command: echo \"x-{{ item }}-y\""
    file.puts "      loop: [\"look-{{ relay }}-ma\"]"
    file.puts "      changed_when: false"
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "derived TRANSFORMED hostile strings stay unsafe (registry closed under derivation)" do
  it "never re-renders a | trim derivative of padded hostile stdout relayed through an author var" do
    canary = File.tempname("unsafe-derived-trim")
    File.delete(canary) if File.exists?(canary)
    status, output = derived_relay_run("trim", canary: canary, padded: true)
    status.success?.must_equal(true, output)
    File.exists?(canary).must_equal(false, "trimmed hostile loop item EXECUTED on the controller:\n#{output}")
  ensure
    File.delete(canary) if canary && File.exists?(canary)
  end

  it "never re-renders a | lower derivative whose text no longer matches any registered leaf" do
    dir = File.dirname(File.tempname("unsafe-derived-lower-probe"))
    canary = File.join(dir, "unsafe-derived-lower-canary")
    hostile = File.join(dir, "UNSAFE-DERIVED-LOWER-CANARY")
    File.delete(canary) if File.exists?(canary)
    File.delete(hostile) if File.exists?(hostile)
    playbook = File.tempname("unsafe-derived-lower", ".yml")
    File.open(playbook, "w") do |file|
      file.puts "- name: derived-taint lower relay"
      file.puts "  hosts: all"
      file.puts "  gather_facts: false"
      file.puts "  vars:"
      file.puts "    relay: \"{{ r.stdout | lower }}\""
      file.puts "  tasks:"
      file.puts "    - name: produce hostile output naming the UPPERCASE path"
      file.puts %(      ansible.builtin.command: echo "{{ '{{' }} lookup('pipe', 'touch #{hostile}') {{ '}}' }}")
      file.puts "      register: r"
      file.puts "    - name: flatten the lowercased derivative into a loop item"
      file.puts "      ansible.builtin.command: echo \"x-{{ item }}-y\""
      file.puts "      loop: [\"look-{{ relay }}-ma\"]"
      file.puts "      changed_when: false"
    end
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s)
    File.exists?(canary).must_equal(false, "lowercased hostile loop item EXECUTED on the controller:\n#{output}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(canary) if canary && File.exists?(canary)
    File.delete(hostile) if hostile && File.exists?(hostile)
  end

  it "still renders a legit author chain relayed the same way (no over-taint)" do
    playbook = File.tempname("unsafe-derived-legit", ".yml")
    File.open(playbook, "w") do |file|
      file.puts "- name: legit derived relay"
      file.puts "  hosts: all"
      file.puts "  gather_facts: false"
      file.puts "  vars:"
      file.puts "    relay: \"{{ b }}\""
      file.puts "    b: \"hello {{ c }}\""
      file.puts "    c: world"
      file.puts "  tasks:"
      file.puts "    - name: flatten the chain into a loop item"
      file.puts "      ansible.builtin.command: echo \"x-{{ item }}-y\""
      file.puts "      loop: [\"look-{{ relay }}-ma\"]"
      file.puts "      register: o"
      file.puts "      changed_when: false"
      file.puts "    - name: show"
      file.puts "      ansible.builtin.debug:"
      file.puts "        msg: \"{{ o.results | map(attribute='stdout') | list }}\""
    end
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("look-hello world-ma",
      "legit author-chain loop item lost its re-render (over-taint):\n#{output}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
