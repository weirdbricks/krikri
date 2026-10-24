require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_items entries written with block tags only" do
  it "renders the item before binding it (wangsha.ansible_role_lynis)" do
    playbook = File.tempname("loop-block-tag", ".yml")
    File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - debug: msg="got={{ item }}"
          with_items:
            - lynis
            - "{% if false %}apt-transport-https{% else %}[]{% endif %}"
    YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("(item=[])")
    output.to_s.wont_include("{% if")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
