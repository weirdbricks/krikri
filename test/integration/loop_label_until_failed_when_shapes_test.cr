require "../minitest_helper"
require "file_utils"

# Loop/until/failed-when console shapes vs ansible-playbook 2.19.11
# (live-verified via scripts/output_parity.sh):
# - a loop_control.label referencing loop_control.index_var sees the index
#   ("LBL-0", not "LBL-undefined");
# - an until:-looped debug task's ok dump is msg-only (no "changed": false);
# - failed_when on a debug task shows the "Action failed." chain and dumps
#   msg-only pretty ({"msg": "fw"}), not the module shape.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop label index / until dump / debug failed_when shapes" do
  it "binds index_var in labels, keeps until dumps clean, uses Action failed for debug" do
    playbook = File.tempname("loop-shapes", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug: msg="idx {{ i }}"
            loop: ['a']
            loop_control:
              index_var: i
              label: "LBL-{{ i }}"
          - debug: msg="trying"
            until: true
            retries: 2
            delay: 0
          - debug: msg="fw"
            failed_when: true
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("ok: [localhost] => (item=LBL-0) =>")
    text.must_include("ok: [localhost] => {\n    \"msg\": \"trying\"\n}")
    text.must_include("[ERROR]: Task failed: Action failed: fw")
    text.must_include("fatal: [localhost]: FAILED! => {\n    \"msg\": \"fw\"\n}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
