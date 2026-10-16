require "../minitest_helper"
require "file_utils"

# Issue #132: a DEFINED null is not undefined - Ansible's mandatory filter
# passes a null through (it renders as an empty string) and fails only for a
# genuinely UNDEFINED variable, with its filter-plugin wrapper. Both shapes
# live-verified against ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "mandatory filter with a defined null (issue #132)" do
  it "renders a null value as empty and still fails on undefined" do
    playbook = File.tempname("mandatory-null", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          hm_geoip__account_id:
        tasks:
          - debug:
              msg: "AccountID {{ hm_geoip__account_id | mandatory }}"
          - debug:
              msg: "X {{ definitely_missing | mandatory }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("\"msg\": \"AccountID \"")
    text.must_include("The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'definitely_missing' not defined.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
