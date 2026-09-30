require "../minitest_helper"
require "file_utils"

# A play/task `vars:` entry using one of ansible-core's reserved variable
# names warns at compile time: "[WARNING]: Found variable using reserved
# name 'X'." + an Origin block naming the var key's own position, one
# blank line after each block. Byte-for-byte vs real ansible-playbook
# 2.19.11 (pr.yml-shape probes via scripts/output_parity.sh).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "reserved variable name warning" do
  it "warns for play vars and task vars with the key's own Origin" do
    playbook = File.tempname("reserved-var", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          range: "x"
          with_items: "not reserved"
        tasks:
          - debug: msg="hi"
            vars:
              lookup: "y"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'range'.")
    text.must_include("[WARNING]: Found variable using reserved name 'lookup'.")
    # `with_items` (a prefix-form reserved entry) never warns
    refute(text.includes?("[WARNING]: Found variable using reserved name 'with_items'."))
    text.must_include("Origin: #{playbook}:4:5")
    text.must_include("Origin: #{playbook}:9:9")
    # exactly one Origin block per warning, blank line after each
    text.scan("Found variable using reserved name").size.must_equal(2)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
