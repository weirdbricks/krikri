require "../minitest_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since these shapes are resolved at execution
# time by TaskExecutor#resolve_loop_template / #resolve_loop_nested /
# #resolve_loop_together, private methods not reachable from a unit spec
# without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("loop-wrapped-source-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop sources holding a list-producing template" do
  it "runs loop:/with_list: array-wrapped sources as one iteration but still flattens with_items:" do
    # Ansible's three shapes, side by side, all live-verified against
    # ansible-core 2.19.11 on this machine:
    #   loop: ["{{ bl }}"]          -> ONE item, the whole list
    #   with_items: ["{{ bl }}"]    -> THREE items (with_items splices a
    #                                  nested list element one level)
    #   loop: [x, "{{ bl }}"]       -> two items: x, then the whole list
    # with_list: is loop: under its legacy name, so it follows the first
    # row too - it used to be routed through the generic `with_<lookup>`
    # fallback as a nonexistent "list" lookup, which spliced the list into
    # three items instead.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bl: [a, b, c]
        tasks:
          - name: loop wrapped
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ bl }}"
            register: loop_result
          - name: with_items wrapped
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items:
              - "{{ bl }}"
            register: with_items_result
          - name: loop mixed
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - x
              - "{{ bl }}"
            register: mixed_result
          - name: with_list wrapped
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_list:
              - "{{ bl }}"
            register: with_list_result
          - name: assert
            ansible.builtin.assert:
              that:
                - loop_result.results | length == 1
                - loop_result.results[0].item == ['a', 'b', 'c']
                - loop_result.results[0].msg == ['a', 'b', 'c']
                - with_items_result.results | length == 3
                - with_items_result.results[0].msg == "a"
                - with_items_result.results[2].msg == "c"
                - mixed_result.results | length == 2
                - mixed_result.results[0].msg == "x"
                - mixed_result.results[1].item == ['a', 'b', 'c']
                - with_list_result.results | length == 1
                - with_list_result.results[0].item == ['a', 'b', 'c']
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "keeps iterating the list for the direct (non-array-wrapped) loop: form" do
    # The counterpart rule, so the array-wrapped fix above can't swallow
    # the direct form: with no square brackets in the YAML, the templated
    # value IS the item list and really is iterated (live-verified against
    # ansible-core 2.19.11).
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bl: [a, b, c]
        tasks:
          - name: loop direct
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ bl }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 3
                - result.results[0].item == "a"
                - result.results[2].item == "c"
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "keeps a filter-chain-wrapped loop: source as one iteration" do
    # Same rule when the element isn't a bare variable reference but a
    # filter chain, which takes the evaluator/parse path instead of the
    # direct variable lookup (live-verified against 2.19.11).
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bl: [a, b, c]
        tasks:
          - name: loop wrapped filter
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ bl | sort }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 1
                - result.results[0].item == ['a', 'b', 'c']
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end

  it "resolves with_nested:/with_together: array-wrapped sources to real factors and columns" do
    # with_nested:/with_together: take a list of independent factors/
    # columns, so their one-element ARRAY form is a single `{{ var }}`
    # SOURCE, not an item list - Ansible zips/iterates the resolved
    # list's own elements into one row per element (live-verified against
    # ansible-core 2.19.11: three one-element rows here). Reading that
    # array as "the whole source is secretly a list-producing template"
    # instead ran with_together: through a resolver that does not exist
    # at all, so the task ran ONCE with `item` unbound ("'item' is
    # undefined"), and gave with_nested: the wrong cartesian product.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bl: [a, b, c]
        tasks:
          - name: nested wrapped
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_nested:
              - "{{ bl }}"
            register: nested_result
          - name: together wrapped
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_together:
              - "{{ bl }}"
            register: together_result
          - name: assert
            ansible.builtin.assert:
              that:
                - nested_result.results | length == 3
                - nested_result.results[0].item == ['a']
                - nested_result.results[2].item == ['c']
                - together_result.results | length == 3
                - together_result.results[0].item == ['a']
                - together_result.results[2].item == ['c']
      YAML

    status.success?.must_equal(true)
    output.must_include("All assertions passed")
  end
end
