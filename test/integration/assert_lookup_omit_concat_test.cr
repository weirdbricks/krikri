require "../minitest_helper"

# `lookup('ini', '... default=' + omit)` inside assert: Ansible fails the
# task ("Error rendering expression: can only concatenate str (not
# "_OmitType") to str", live-verified vs ansible-core 2.19.11); krikri let
# the PlusMinusOperandError escape the lookup's argument evaluation and
# crashed the whole process with an unhandled-exception stack dump.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "assert with a str + omit lookup argument" do
  it "fails the task with the expression render error instead of crashing" do
    playbook = File.tempname("assert-lookup-omit", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: lookup ini plugin is ok
            assert:
              that: "lookup('ini', 'a section=s file=/nonexistent.ini default=' + omit) == 'b'"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include(%(Task failed: Error rendering expression: can only concatenate str (not "_OmitType") to str))
    text.wont_include("Unhandled exception")
    text.must_include("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
