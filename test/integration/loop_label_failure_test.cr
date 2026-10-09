require "../minitest_helper"
require "file_utils"

# A loop_control.label that fails to template fails the ITEM (and through
# the aggregation, the task) - ansible-core templats the label for the
# item's result line and surfaces the failure there. The old silent
# fallback rendered the label as the "undefined" sentinel text and let
# the task sail through as ok where real fails it (round 5250000,
# veselahouba.openvpn's `label: "{{ openvpn_client.name }}"` over a dict
# item). Verified against ansible-playbook 2.19.11 before being encoded
# here.
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
