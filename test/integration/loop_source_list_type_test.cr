require "../minitest_helper"
require "file_utils"

# A loop: source that IS defined but isn't a list is a hard type error in
# Ansible, with its own distinct wording. Live-verified against
# ansible-core 2.19.12 on Rocky 9.6 (round174 differential matrix
# scenarios 11a and 11c) - this engine used to run the task once with
# `item` bound to the non-list value.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("loop-list-type", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop: source must resolve to a list" do
  # Scenario 11a - verbatim real-Ansible wording, backticks and all.
  it "rejects an explicit null source as NoneType" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          nullvar: null
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ nullvar }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.must_include("failed=1")
  end

  # Scenario 11c.
  it "rejects a scalar string source as str" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          scalarvar: "hello"
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ scalarvar }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("The `loop` value must resolve to a 'list', not 'str'.")
    output.must_include("failed=1")
  end

  # The legacy array-wrapped form (`with_items: ["{{ var }}"]`) keeps its
  # documented flatten-a-scalar-to-one-item leniency - that is a
  # different source shape, and loop_scalar_flatten_spec.cr pins it.
  it "keeps the array-wrapped form's scalar-flatten leniency" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          scalarvar: "hello"
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "got {{ item }}"
            with_items:
              - "{{ scalarvar }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("got hello")
    output.wont_include("must resolve to a 'list'")
  end

  it "resolves a vars:-level ternary selecting between two real lists, not just a string" do
    # Real bug found via Oefenweb.percona_client's own vars/main.yml:
    # `percona_client_repositories: "{{ percona_client_repositories_8 if
    # percona_client_version is version('8.0', '==') else
    # percona_client_repositories_5 }}"` (a ternary choosing between two
    # role-default LISTS), used directly as `with_items:`. Ansible
    # resolves the ternary to the actual list and iterates it fine;
    # resolve_template_value's own re-render step used to go through
    # ExpressionEvaluator#evaluate + JSON.parse, which only ever sees
    # Crinja's Python-repr display text for a container result (single-
    # quoted, not valid JSON) - JSON.parse always failed, and the whole
    # repr STRING got wrapped as the "resolved" value instead of a real
    # array, so this failed with "The `loop` value must resolve to a
    # 'list', not 'str'." even though the ternary genuinely picks a list.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          list_a:
            - {url: "http://a"}
          list_b:
            - {url: "http://b"}
          which: "8.0"
          picked_list: "{{ list_a if which is version('8.0', '==') else list_b }}"
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "{{ item.url }}"
            with_items: "{{ picked_list }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("http://a")
    output.wont_include("must resolve to a 'list'")
  end

  it "with_items: wraps a DIRECT (non-array-wrapped) scalar source into one iteration, unlike loop:'s own strict-fail" do
    # Real bug found via a live 100-role confirm round:
    # diodonfrost.amazon_codedeploy's own `with_items: "{{ package_
    # requirements }}"`, where package_requirements is itself a
    # `{%- if -%}...{%- endif -%}` block-tag expression resolving to a
    # plain scalar. Two separate bugs, both fixed together:
    # (1) resolve_template_value only re-rendered a raw value
    # containing "{{" - a PURE block-tag expression (no literal "{{" at
    # all) was returned unrendered, so the loop source stayed the raw
    # "{%- if -%}..." text; (2) with_items: was treated identically to
    # loop:'s own strict "must resolve to a list" rule for a
    # non-array-wrapped scalar source - verified live against
    # ansible-core 2.19.12 that with_items: has its OWN, more lenient
    # legacy behavior: it ALWAYS wraps a non-list resolution into a
    # single-item iteration (`with_items: "{{ myscalar }}"` succeeds
    # with exactly one item), while loop: genuinely hard-fails the same
    # shape ("The `loop` value must resolve to a 'list', not 'str'.").
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          package_requirements: >-
            {%- if false -%}
            ruby2.0
            {%- else -%}
            ruby
            {%- endif -%}
        tasks:
          - name: with_items on a block-tag scalar
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_items: "{{ package_requirements }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("item=ruby")
    output.wont_include("must resolve to a 'list'")
  end

  it "loop: still hard-fails a direct (non-array-wrapped) scalar source, unlike with_items:'s own leniency" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          myscalar: "ruby"
        tasks:
          - name: loop on a direct scalar
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: "{{ myscalar }}"
      YAML

    status.success?.must_equal(false)
    output.must_include("must resolve to a 'list', not 'str'")
  end

  it "keeps a block-tag set_fact whose rendered output looks like a list literal a plain string" do
    # Found live benchmarking HanXHX.debian_bootstrap: its
    # `dbs_repo_old: "{% if false %}{{ x }}{% else %}['dummy']{% endif %}"`
    # default renders to text that happens to look like a Python list
    # literal, but ansible-core (2.19.11, live-verified) never
    # natively types block-tag output - native typing requires the
    # template's whole parsed AST to be exactly one output node wrapping
    # one expression, so this stays the literal STRING "['dummy']"
    # (`is string` -> True). The set_fact coercion path used to re-parse
    # the repr-looking text into a real array, so the loop below
    # silently iterated where Ansible hard-fails.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: block-tag if/else producing a bracket-looking string
            ansible.builtin.set_fact:
              dbs_repo_old: "{% if false %}{{ x }}{% else %}['dummy']{% endif %}"

          - name: show type
            ansible.builtin.debug:
              msg: "type is {{ dbs_repo_old is string }} value={{ dbs_repo_old }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("type is True value=['dummy']")
  end

  it "hard-fails a loop: over a block-tag set_fact that stayed a string, with Ansible's exact error" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: block-tag if/else producing a bracket-looking string
            ansible.builtin.set_fact:
              dbs_repo_old: "{% if false %}{{ x }}{% else %}['dummy']{% endif %}"

          - name: looped
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: "{{ dbs_repo_old }}"
      YAML

    status.success?.must_equal(false)
    output.must_include("The `loop` value must resolve to a 'list', not 'str'.")
    output.must_include("failed=1")
  end
end

# Round 829240 (ngine_io.blocky_dns): a single-element with_items entry
# that is mixed text around TWO spans ("{{ a }}/{{ b }}") also starts
# with "{{" and ends with "}}" - the old check treated it as a
# list-producing loop SOURCE, stripped it greedily into the expression
# "a }}/{{ b", and failed with "'a }}/{{ b' is undefined". Ansible
# treats it as one literal loop item whose embedded templates render at
# item time.
describe "single-element with_items with TWO spans" do
  it "is one literal loop item, rendered at item time" do
    src_dir = File.tempname("two-span-loop-item")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          base: /tmp/two-span-loop
          version: "1.0.0"
        tasks:
          - file:
              path: "{{ item }}"
              state: directory
              mode: "0755"
            with_items:
              - "{{ base }}/{{ version }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)
    text = output.to_s
    status.success?.must_equal(true, text)
    text.wont_include("is undefined")
    text.must_include("changed:")
    File.directory?("/tmp/two-span-loop/1.0.0").must_equal(true)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
    `rm -rf /tmp/two-span-loop`
  end
end

# A loop source var whose own value is a literal string with embedded
# spans (`relay: "{{ mixed }}"`, `mixed: "a-{{ lookup('env','HOME') }}-b"`)
# must render once and iterate the RESULT. Live-verified against
# ansible-playbook 2.19.11: on a play carrying all three loop-source
# shapes, this engine pre-fix bound BOTH relay-shaped sources to the
# literal "undefined" sentinel (it stripped the outer braces of a value
# that merely starts/ends with a span and evaluated the leftovers
# "a- ... -b" as ONE expression).
describe "loop sources whose resolved value is itself MIXED template text" do
  # The pre-fix failure needed the whole shape family in one play; each
  # two-task subset already rendered correctly, so this mirrors the full
  # reproduction (scalar + array-wrapped + two-element) and asserts on
  # the two relay-bound tasks.
  it "renders all relayed loop sources in a play mixing the three shapes" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mixed: "a-{{ lookup('env', 'HOME') }}-b"
          plain: hello
        tasks:
          - name: scalar source
            ansible.builtin.debug:
              msg: "scalar item={{ item }}"
            with_items: "{{ mixed }}"
          - name: wrapped source
            ansible.builtin.debug:
              msg: "wrapped item={{ item }}"
            with_items: ["{{ mixed }}"]
          - name: mixed plus plain
            ansible.builtin.debug:
              msg: "two item={{ item }}"
            loop: ["{{ mixed }}", "{{ plain }}"]
      YAML
    status.success?.must_equal(true, output)
    output.must_include("scalar item=a-#{ENV["HOME"]}-b")
    output.must_include("wrapped item=a-#{ENV["HOME"]}-b")
    output.must_include("two item=a-#{ENV["HOME"]}-b")
    output.wont_include("item=undefined")
  end
end
