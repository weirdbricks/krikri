require "../minitest_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_loop_nested, a private method not reachable from
# a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("with-nested-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_nested: templated scalar sources" do
  it "expands each {{ var }} source to its real list at runtime" do
    # Real bug found benchmarking gantsign.sdkman: the parser's
    # with_nested: branch wrapped every scalar entry - including a whole
    # `{{ var }}` list reference - as a ONE-element literal list at parse
    # time, pinning each cartesian factor to size 1 no matter how many
    # elements the variable actually held. The loop iterated once per
    # outer source with `item` = the whole rendered inner list, where
    # real Ansible iterates once per PAIR of elements.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          user_list: [alice, bob]
          group_list: [dev, ops]
        tasks:
          - name: nested loop
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - "{{ user_list }}"
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 4
                - result.results[0].msg == "alice-dev"
                - result.results[1].msg == "alice-ops"
                - result.results[2].msg == "bob-dev"
                - result.results[3].msg == "bob-ops"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "yields zero iterations when a templated source resolves to an empty list" do
    # The "including zero" half of the same root cause: an empty source
    # var made the parse-time pinning INVISIBLE (1x1 still ran), but the
    # runtime-resolved product must be 0 - task skipped, not run once
    # with a whole-list item.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          user_list: []
          group_list: [dev, ops]
        tasks:
          - name: nested loop over empty source
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - "{{ user_list }}"
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 0
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "keeps a mixed literal + templated source list working" do
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          group_list: [dev, ops]
        tasks:
          - name: nested loop, mixed sources
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - [alice, bob]
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 4
                - result.results[0].msg == "alice-dev"
                - result.results[3].msg == "bob-ops"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "iterates a literal string term one element per character" do
    # Real ansible-core 2.19.11 (live-verified): the nested lookup
    # iterates each term directly as a sequence, so a literal string
    # term contributes one element per CHARACTER - `with_nested: [cd,
    # [1]]` yields [c,1] then [d,1], where krikri used to keep "cd"
    # whole as a one-element factor.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: nested loop over a literal string term
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested: [cd, [1]]
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 2
                - result.results[0].msg == "c-1"
                - result.results[1].msg == "d-1"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "iterates a substituted embedded-template literal per character too" do
    # The deferred-source path (a literal entry with embedded {{ }}): real
    # Ansible templates the term and THEN iterates the resulting string
    # per character (live-verified: "a-{{ x }}-b" over x=12 iterates
    # a,-,1,2,-,b), so krikri's executor fallback must char-split the
    # substituted string, not keep it as one element.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          x: "12"
        tasks:
          - name: nested loop over an embedded-template literal
            ansible.builtin.debug:
              msg: "{{ item.0 }}"
            with_nested:
              - "a-{{ x }}-b"
              - [1]
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 6
                - result.results[0].item.0 == "a"
                - result.results[1].item.0 == "-"
                - result.results[2].item.0 == "1"
                - result.results[3].item.0 == "2"
                - result.results[4].item.0 == "-"
                - result.results[5].item.0 == "b"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "expands a direct scalar source's string terms per character" do
    # The DIRECT scalar form (`with_nested: "{{ var }}"`) resolves to the
    # term LIST at runtime; real Ansible then iterates each term as a
    # sequence (live-verified: over combos = ["cd", [1]] it yields [c,1]
    # then [d,1]).
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          combos: ["cd", [1]]
        tasks:
          - name: nested loop from a scalar source
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested: "{{ combos }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 2
                - result.results[0].msg == "c-1"
                - result.results[1].msg == "d-1"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end
end
