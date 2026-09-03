require "../spec_helper"

# A loop: source that IS defined but isn't a list is a hard type error in
# real Ansible, with its own distinct wording. Live-verified against
# ansible-core 2.19.12 on Rocky 9.6 (round174 differential matrix
# scenarios 11a and 11c) - this engine used to run the task once with
# `item` bound to the non-list value.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

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

    status.exit_code.should eq(2)
    output.should contain("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.should contain("failed=1")
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

    status.exit_code.should eq(2)
    output.should contain("The `loop` value must resolve to a 'list', not 'str'.")
    output.should contain("failed=1")
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

    status.success?.should be_true
    output.should contain("got hello")
    output.should_not contain("must resolve to a 'list'")
  end

  it "resolves a vars:-level ternary selecting between two real lists, not just a string" do
    # Real bug found via Oefenweb.percona_client's own vars/main.yml:
    # `percona_client_repositories: "{{ percona_client_repositories_8 if
    # percona_client_version is version('8.0', '==') else
    # percona_client_repositories_5 }}"` (a ternary choosing between two
    # role-default LISTS), used directly as `with_items:`. Real Ansible
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

    status.success?.should be_true
    output.should contain("http://a")
    output.should_not contain("must resolve to a 'list'")
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

    status.success?.should be_true
    output.should contain("item=ruby")
    output.should_not contain("must resolve to a 'list'")
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

    status.success?.should be_false
    output.should contain("must resolve to a 'list', not 'str'")
  end
end
