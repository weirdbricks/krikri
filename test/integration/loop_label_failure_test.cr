require "../minitest_helper"
require "file_utils"

# A loop_control.label that fails to template fails the ITEM (and through
# the aggregation, the task) - ansible-core templats the label for the
# item's result line and surfaces the failure there. The old silent
# fallback rendered the label as the "undefined" sentinel text and let
# the task sail through as ok where real fails it (round 5250000,
# veselahouba.openvpn's `label: "{{ openvpn_client.name }}"` over a dict
# item). Verified against ansible-playbook 2.19.11 before being encoded
# here. The block-skip half: real STILL templates the label per item when
# a task is skipped by an enclosing block's False when:, so a bad label
# converts the skip into a task failure carrying the enclosing chain's
# false_condition (round 5280000, same role's `label:
# "{{ openvpn_client.name }}"` over `openvpn_clients: {}` inside a
# `when: openvpn_ca_master` block) - krikri used to skip the block's
# children before their loops ran and just skip instead (rc=0 where real
# exits rc=2).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop_control.label templating failure (loop_label_failure_test.cr)" do
  it "fails the item and the task when the label cannot template" do
    playbook = File.tempname("loop-label", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          d2:
            a: 1
            b: 2
        tasks:
          - debug:
              msg: "x"
            with_items: "{{ d2 }}"
            loop_control:
              label: "{{ item.name }}"
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    text.must_include("failed: [localhost] (item=None) =>")
    text.must_include("Failed to template loop_control.label: object of type 'dict' has no attribute 'name'")
    text.must_include("One or more items failed")
    text.must_match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a block-skipped looped task whose label cannot template (round 5280000)" do
    playbook = File.tempname("blockskip-label", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          openvpn_clients: {}
          openvpn_ca_master: false
        tasks:
          - block:
              - name: Register clients
                file:
                  dest: /tmp/should-not-run-krikri-test
                  state: touch
                with_items: "{{ openvpn_clients }}"
                loop_control:
                  loop_var: openvpn_client
                  label: "{{ openvpn_client.name }}"
            when: openvpn_ca_master
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    # Real's exact failed line (the block's False when: rides along as
    # skip_reason/false_condition on the failed result, and the loop var
    # is bound to the item - the dict itself, shown as {} for the
    # item=None display label).
    text.must_include(%q{failed: [localhost] (item=None) => {"ansible_loop_var": "openvpn_client", "changed": false, "false_condition": "openvpn_ca_master", "msg": "Failed to template loop_control.label: object of type 'dict' has no attribute 'name'", "openvpn_client": {}, "skip_reason": "Conditional result was False"}})
    # No skipping lines at all: the one item became the failure.
    text.includes?("skipping:").must_equal(false)
    text.must_match(/failed=1\b/)
    text.must_match(/skipped=0\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails each label-broken item of a block-skipped multi-item loop once in the recap" do
    playbook = File.tempname("blockskip-label-multi", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          openvpn_clients:
            - common_name: alice
            - common_name: bob
          openvpn_ca_master: false
        tasks:
          - block:
              - name: Register clients
                file:
                  dest: /tmp/should-not-run-krikri-test
                  state: touch
                with_items: "{{ openvpn_clients }}"
                loop_control:
                  loop_var: openvpn_client
                  label: "{{ openvpn_client.name }}"
            when: openvpn_ca_master
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    text.must_include(%q{"openvpn_client": {"common_name": "alice"}, "skip_reason": "Conditional result was False"})
    text.must_include(%q{"openvpn_client": {"common_name": "bob"}, "skip_reason": "Conditional result was False"})
    # The recap counts the TASK failed once, not per item (live-verified
    # vs 2.19.11), and there is no all-items-skipped aggregate when every
    # item failed.
    text.must_match(/failed=1\b/)
    text.must_match(/skipped=0\b/)
    text.includes?("All items skipped").must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps plain skips alongside a failed item and prints the All items skipped fatal (mixed)" do
    playbook = File.tempname("blockskip-label-mixed", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          openvpn_clients:
            - name: alice
            - common_name: bob
          openvpn_ca_master: false
        tasks:
          - block:
              - debug:
                  msg: "x"
                with_items: "{{ openvpn_clients }}"
                loop_control:
                  loop_var: openvpn_client
                  label: "{{ openvpn_client.name }}"
            when: openvpn_ca_master
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    # The label that renders keeps its skipping line (with the rendered
    # item), the broken one fails msg-only single-line (debug: strips
    # the skip context, and the skip result carries no
    # _ansible_verbose_always, so the dump follows normal verbosity),
    # and the aggregation still says All items skipped - exactly real's
    # mixed shape (live-verified vs 2.19.11).
    text.must_include("skipping: [localhost] => (item=alice)")
    text.must_include(%q{failed: [localhost] (item=None) => {"msg": "Failed to template loop_control.label: object of type 'dict' has no attribute 'name'"}})
    text.must_include(%q{fatal: [localhost]: FAILED! => {"msg": "All items skipped"}})
    text.must_match(/failed=1\b/)
    text.must_match(/skipped=0\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps a non-debug block-skipped mixed loop free of the All items skipped fatal" do
    playbook = File.tempname("blockskip-label-file-mixed", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - block:
              - file:
                  dest: /tmp/should-not-run-krikri-test
                  state: touch
                with_items:
                  - name: alice
                  - common_name: bob
                loop_control:
                  loop_var: oc
                  label: "{{ oc.name }}"
            when: false
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(false)
    # A literal `when: false` stays a boolean in false_condition (not the
    # string "false"), the rendered label keeps its skipping line, and a
    # non-debug module prints no All items skipped aggregate (all shapes
    # live-verified vs 2.19.11).
    text.must_include("skipping: [localhost] => (item=alice)")
    text.must_include(%q{"false_condition": false, "msg": "Failed to template loop_control.label: object of type 'dict' has no attribute 'name'", "oc": {"common_name": "bob"}, "skip_reason": "Conditional result was False"})
    text.includes?("All items skipped").must_equal(false)
    text.must_match(/failed=1\b/)
    text.must_match(/skipped=0\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps a working label rendering unchanged" do
    playbook = File.tempname("loop-label-ok", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          items:
            - name: one
            - name: two
        tasks:
          - debug:
              msg: "x"
            with_items: "{{ items }}"
            loop_control:
              label: "{{ item.name }}"
      YAML
    )
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    text.must_include("(item=one)")
    text.must_include("(item=two)")
    text.must_match(/ok=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
