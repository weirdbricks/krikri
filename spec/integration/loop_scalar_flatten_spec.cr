require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_loop_template / #resolve_template_value, private
# methods not reachable from a unit spec without constructing a whole
# TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("loop-scalar-flatten-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop:/with_items: single-element list holding a template that resolves to a scalar" do
  it "runs exactly one iteration with the scalar as item, matching real ansible-playbook" do
    # Real bug found immediately after auditing (and fixing) 8 copies of
    # the recursive-re-templating gap: `["{{ scalar_var }}"]` is real
    # Ansible's own "with_items: flattens one level" idiom - the parser
    # (find_loop_template) can only detect the SHAPE at parse time (one
    # bare {{ }} span as the array's sole element), not whether the
    # referenced variable will turn out to be a list or a scalar at
    # runtime. #resolve_loop_template's own `value.as_a?` returned nil
    # for a scalar, which fell through every other loop resolver too and
    # left the task with NO loop items at all - not skipped, not looped,
    # run once with `item` silently "undefined" instead of the real
    # value. Verified against real ansible-playbook directly: `loop:`
    # and `with_items:` both treat this identically, not just
    # with_items:'s own documented legacy flatten behavior.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          scalar_var: 42
        tasks:
          - name: loop scalar
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ scalar_var }}"
            register: loop_result
          - name: with_items scalar
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items:
              - "{{ scalar_var }}"
            register: with_items_result
          - name: assert
            ansible.builtin.assert:
              that:
                - loop_result.results | length == 1
                - loop_result.results[0].msg == "42"
                - with_items_result.results | length == 1
                - with_items_result.results[0].msg == "42"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "still flattens a genuine list correctly (no regression)" do
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          list_var: [a, b, c]
        tasks:
          - name: loop real list
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ list_var }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 3
                - result.results[0].msg == "a"
                - result.results[2].msg == "c"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "resolves loop: source itself when its raw value is still unrendered Jinja" do
    # A second, related gap found alongside the fix above:
    # #resolve_template_value (resolving the loop: SOURCE, e.g. `loop:
    # "{{ templated_default }}"`) had the identical missing re-render
    # guard - templated_default's own raw value being "{{ real_list }}"
    # (a role default computed from another default) was returned as-
    # is, so the caller's own value.as_a? check always failed against
    # the literal unrendered text.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          templated_default: "{{ real_list }}"
          real_list: [x, y]
        tasks:
          - name: loop templated source
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ templated_default }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 2
                - result.results[0].msg == "x"
                - result.results[1].msg == "y"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end
end
