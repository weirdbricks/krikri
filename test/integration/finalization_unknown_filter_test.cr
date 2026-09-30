require "../minitest_helper"
require "file_utils"

# An unknown FILTER (or test) name inside a task arg is a template COMPILE
# error: real ansible-core 2.19.11 routes it through the same "Finalization
# of task args" chain as an undefined variable ("... failed: Error while
# resolving value for 'msg': Syntax error in template: No filter named
# 'ljust'."), and the inner Origin stanza points at the failing param KEY's
# first character on the module line even for flow style (`- debug: msg=...`
# -> column 14). Live-compared byte for byte with real ansible-playbook
# 2.19.11 via scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (unknown filter)" do
  it "wraps an unknown-filter arg error in the finalization chain with the param's own origin" do
    playbook = File.tempname("finalization-unknown-filter", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: msg="x{{ 'hi' | ljust(5) }}y"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.")
    text.must_include("Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.\nOrigin: #{playbook}:4:30")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
