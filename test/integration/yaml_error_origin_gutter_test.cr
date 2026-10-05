require "../minitest_helper"
require "file_utils"

# YAML parse-failure Origin blocks pad the line-number gutter to the
# offending line's width (" 9" before "10") and show up to TWO leading
# context lines - byte-compared vs ansible-playbook 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "YAML parse error Origin block" do
  it "pads the gutter and shows two context lines" do
    playbook = File.tempname("yaml-origin", ".yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug: msg="{{ d | dict2items }}"
          - debug: msg="x"
          - debug: msg="{{ {'a': {1: 1}} | combine({'a': {2: 2}}) }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Origin: #{playbook}:7:26")
    text.must_include("\n5     - debug: msg=\"{{ d | dict2items }}\"\n6     - debug: msg=\"x\"\n7     - debug: msg=")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
