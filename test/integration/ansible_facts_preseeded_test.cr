require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-two-local-hosts.ini")

describe "ansible_facts with gather_facts: false" do
  it "is a defined empty dict, so subscripting fails with 'no attribute', not 'undefined'" do
    playbook = File.tempname("ansible-facts-preseeded", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug:
              msg: "defined={{ ansible_facts is defined }} json={{ ansible_facts | to_json }}"
          - debug:
              msg: "{{ ansible_facts['os_family'] }}"
            ignore_errors: true
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    text.must_include("defined=True json={}")
    text.must_include("object of type 'dict' has no attribute 'os_family'")
    text.wont_include("'ansible_facts' is undefined")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
