require "../minitest_helper"
require "file_utils"

# Strict-undefined message naming, mandatory's filter-plugin failure
# wrapper, and the nameless-task when: error chain - byte-compared with
# real ansible-playbook 2.19.11 via scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "strict undefined / mandatory / when-error console shapes" do
  it "names the chain root, wraps mandatory, prints the nameless-when chain" do
    playbook = File.tempname("strict-shapes", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug: msg="{{ missing['key'] }}"
            ignore_errors: true
          - debug: msg="{{ definitely_missing | mandatory }}"
            ignore_errors: true
          - debug: msg="x"
            when: undefined_condition_var == "y"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Error while resolving value for 'msg': 'missing' is undefined")
    text.must_include("The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'definitely_missing' not defined.")
    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: 'undefined_condition_var' is undefined")
    text.must_include("Error while evaluating conditional: 'undefined_condition_var' is undefined\nOrigin: #{playbook}:9:13")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
