require "../minitest_helper"
require "file_utils"

# A loop_control.label that yields a dict/list is stringified as Python
# repr, as Jinja does, not compact JSON (Oefenweb.rsync_sync, issue #152:
# `label: "{{ item.stat }}"`). Expected text verified against
# ansible-playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop_control.label Python repr (loop_label_python_repr_test.cr)" do
  it "renders a dict label with single quotes, True/False/None" do
    playbook = File.tempname("loop-label-repr", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: hi
            loop:
              - {a: 1, b: [x, y], c: true, d: null, e: "s"}
            loop_control:
              label: "{{ item }}"
      YAML
    )
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("(item={'a': 1, 'b': ['x', 'y'], 'c': True, 'd': None, 'e': 's'})")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
