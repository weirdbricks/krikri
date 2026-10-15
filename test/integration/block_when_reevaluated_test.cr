require "../minitest_helper"

# Ansible (2.19.11) inherits a block's `when:` onto every child task and
# re-evaluates it per task, so a child that changes a variable the
# condition reads makes the later children skip (arillso.fqdn).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "block when re-evaluation" do
  it "skips later block tasks once an earlier task flips the block's condition" do
    playbook = PluginSpecHelper.tmp_path("block-when-reeval-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      connection: local
      vars:
        flag: oldname
      tasks:
        - block:
            - set_fact:
                flag: newname
            - debug: msg="pt2 ran"
          when: flag == "oldname"
    YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
    text = output.to_s
    text.includes?("skipping: [localhost]").must_equal(true, text)
    text.includes?("pt2 ran").must_equal(false, text)
    text.includes?("ok=1 ").must_equal(true, text)
    text.includes?("skipped=1 ").must_equal(true, text)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
