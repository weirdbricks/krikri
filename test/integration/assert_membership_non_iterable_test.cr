require "../minitest_helper"

# `assert: that:` evaluates its item through the same ConditionalEvaluator
# as when:, so a membership test against a null container must fail the
# task exactly as real ansible does (issue #1911's root cause): Python's
# `in` needs an iterable right operand, and real words the failure
# "Task failed: Error rendering expression: argument of type 'NoneType'
# is not iterable" with the that: item as the chain's second Origin
# (live-verified vs ansible-core 2.21.6).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "assert membership against a null container" do
  it "fails with the expression render error" do
    playbook = File.tempname("assert-membership-none", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          my_none: null
        tasks:
          - name: membership in none
            assert:
              that:
                - "'x' in my_none"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Error rendering expression: argument of type 'NoneType' is not iterable")
    text.must_include("<<< caused by >>>\n\nError rendering expression: argument of type 'NoneType' is not iterable")
    text.must_include(%("msg": "Task failed: Error rendering expression: argument of type 'NoneType' is not iterable"))
    text.must_include("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
