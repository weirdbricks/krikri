require "../minitest_helper"
require "file_utils"

# The REGISTERED shape of a looped task whose `when:` skipped items, and
# of the plain non-looped skip beside it, pinned key-order-and-all to
# ansible-core 2.19.11 (a real-ansible run of the same playbook, with
# `{{ x | to_json }}` of each register). Real records EVERY iterated item
# in the loop's `results` - a when:-false one carrying the same
# conditional-skip dict its non-looped skip uses, with that item's own
# loop bindings appended - so a later `loop: "{{ earlier.results }}"`
# iterates them and prints one `skipping:` line each. The order is not
# cosmetic: the dump renders a dict in insertion order, which is exactly
# what a playbook reading those results back sees.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible's per-item conditional-skip dict, in its own key order, with the
# item and the loop variable name filled in per call site.
private def skipped_item(item : String, false_condition : String) : String
  %({"changed": false, "skipped": true, "skip_reason": "Conditional result was False", ) +
    %("false_condition": #{false_condition}, "item": "#{item}", "ansible_loop_var": "item"})
end

# The same entry as it appears on the `(item=...)` label of a skipping
# line: Python's repr of the dict, not JSON - single quotes, capitalized
# booleans. Spelled out rather than derived from skipped_item so the
# rendering under test is pinned literally, not through a rewriter.
private def skipped_item_repr(item : String) : String
  %({'changed': False, 'skipped': True, 'skip_reason': 'Conditional result was False', ) +
    %('false_condition': False, 'item': '#{item}', 'ansible_loop_var': 'item'})
end

# Runs a playbook whose final task writes `{{ r | to_json }}` to a file
# (through copy:, avoiding the display layer's own JSON escaping) and
# returns the dump verbatim - the whole line, because the KEY ORDER is
# half of what is under test.
private def run_registered_dump(yaml : String) : String
  dump = PluginSpecHelper.tmp_path("loop-skip-register-shape.json")
  playbook = File.tempname("loop-skip-register-shape", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  File.read(dump).strip
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "looped task register shape with when:-skipped items" do
  it "registers every skipped item and reports All items skipped" do
    expected = %({"results": [#{skipped_item("a", "false")}, #{skipped_item("b", "false")}], ) +
               %("skipped": true, "msg": "All items skipped", "changed": false})
    run_registered_dump(<<-YAML).must_equal(expected)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: never
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: [a, b]
            when: false
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
  end

  it "registers the skipped item alongside the executed one and reports All items completed" do
    expected = %({"results": [#{skipped_item("a", %("item == 'b'"))}, ) +
               %({"msg": "b", "failed": false, "changed": false, "item": "b", "ansible_loop_var": "item"}], ) +
               %("skipped": false, "msg": "All items completed", "changed": false})
    run_registered_dump(<<-YAML).must_equal(expected)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: half
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: [a, b]
            when: item == 'b'
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
  end

  it "registers the No items in the list shape for an empty loop" do
    expected = %({"changed": false, "skipped": true, "skipped_reason": "No items in the list", "results": []})
    run_registered_dump(<<-YAML).must_equal(expected)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: nothing
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: []
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
  end

  it "binds the custom loop_var and index_var on a skipped item after the skip keys" do
    expected = %({"results": [{"changed": false, "skipped": true, "skip_reason": "Conditional result was False", ) +
               %("false_condition": false, "p": "a", "ansible_loop_var": "p", "i": 0, "ansible_index_var": "i"}], ) +
               %("skipped": true, "msg": "All items skipped", "changed": false})
    run_registered_dump(<<-YAML).must_equal(expected)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: never
            ansible.builtin.debug:
              msg: "{{ p }}"
            loop: [a]
            when: false
            loop_control:
              loop_var: p
              index_var: i
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
  end

  it "iterates an earlier all-skipped loop's results, one skipping line per item" do
    playbook = File.tempname("loop-over-skipped-results", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: never
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: [a, b]
            when: false
            register: r
          - name: iterate the skips
            ansible.builtin.debug:
              msg: "{{ item.item }}"
            loop: "{{ r.results }}"
            when: false
    YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.exit_code.must_equal(0)
    # Only the SECOND task's lines: the first (all-skipped) loop prints its
    # own two item lines plus its bare trailing one.
    body = output.to_s.lines.map(&.chomp)
    lines = body[(body.rindex { |line| line.starts_with?("TASK [") } || 0)..].select { |line| line.starts_with?("skipping:") }
    # One per skipped result entry, then the loop's own trailing bare line -
    # real counts the whole looped task as ONE skipped task in the recap.
    lines.size.must_equal(3)
    lines[0].must_include("item=" + skipped_item_repr("a"))
    lines[1].must_include("item=" + skipped_item_repr("b"))
    lines[2].must_equal("skipping: [localhost]")
    output.to_s.must_include("skipped=2")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "non-looped skipped task register shape" do
  it "registers changed, skipped, skip_reason, false_condition in Ansible's order" do
    expected = %({"changed": false, "skipped": true, "skip_reason": "Conditional result was False", "false_condition": false})
    run_registered_dump(<<-YAML).must_equal(expected)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: never
            ansible.builtin.debug:
              msg: x
            when: false
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML
  end
end

describe "looped task register shape on the batched loop path" do
  # The same shapes have to hold on execute_looped_task_batched - the other
  # site that records a when:-skipped item, reachable only for a NON-local
  # host (loop_batch_eligible? excludes local connections). Safe to run
  # here: a looped debug: computes its whole result on the controller, so
  # the never-connected host opens no SSH session.
  private NONLOCAL_INVENTORY = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-nonlocal-host.ini")

  it "registers every skipped item and reports All items skipped" do
    playbook = File.tempname("batched-loop-skip-register-shape", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: batchhost
        gather_facts: false
        tasks:
          - name: never
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: [a, b]
            when: false
            register: r
          - name: dump
            ansible.builtin.debug:
              msg: "{{ r | to_json }}"
    YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", NONLOCAL_INVENTORY, playbook], output: output, error: output)
    # copy: would need the SSH session this host never opens, so the dump
    # comes back through debug: - un-escaped back out of its display form.
    dumped = output.to_s.gsub("\\\"", "\"")
    dumped.must_include(%(#{skipped_item("a", "false")}, #{skipped_item("b", "false")}]))
    dumped.must_include(%("skipped": true, "msg": "All items skipped", "changed": false}))
    dumped.must_include("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
