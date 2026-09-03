require "../spec_helper"

# A `when:` type test (`is string`/`is not string`/`is number`/etc.)
# whose left-hand operand is a bare function-CALL expression, not a
# plain variable - `lookup('vars', item) is not string` - used to hit
# ConditionalEvaluator's hand-rolled type-test shortcut BEFORE the
# generic Crinja-delegation fallback further down ever got a chance to
# run: it stripped " is not string" off the condition text and used
# whatever remained ("lookup('vars', item)", the whole call, unparsed)
# as a literal vars-hash KEY. That key never exists, so the "value"
# was always nil/undefined - "is not string" was unconditionally true
# regardless of what the lookup actually returned.
#
# Found via inmotionhosting.apache's own "Check required Apache
# variables (strings)" assert (`when: lookup('vars', item) is not
# string or lookup('vars', item) == 0`, looping every required
# variable) - real Ansible skips it (every variable genuinely IS a
# string); this engine ran the ansible.builtin.fail: on every single
# iteration instead.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("when-is-test-call", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "when: <type test> on a bare function-call expression" do
  it "lookup('vars', item) is not string correctly evaluates the call, not its literal text" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          apache_name: apache2
        tasks:
          - name: assert real string vars are skipped
            ansible.builtin.fail:
              msg: "should not run"
            when: lookup('vars', 'apache_name') is not string
      YAML

    status.success?.should be_true
    output.should_not contain("should not run")
    output.should match(/skipped=1\b/)
  end

  it "still fails when the looked-up value genuinely isn't a string" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          apache_port: 80
        tasks:
          - name: assert non-string vars are caught
            ansible.builtin.fail:
              msg: "correctly caught non-string"
            when: lookup('vars', 'apache_port') is not string
      YAML

    status.success?.should be_false
    output.should contain("correctly caught non-string")
  end
end
