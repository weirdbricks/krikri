require "../minitest_helper"

# Issue #1133 (damianlewis.octobercms): a module failure under a failed_when:
# that itself evaluates True must (a) move the module's exception under
# failed_when_suppressed_exception and (b) replace the [ERROR] block's text
# with "A 'failed_when' expression evaluated to 'True'." while the dumped msg
# stays the module's own (live-verified vs ansible-playbook 2.21.6, where
# UnifiedTaskResult.set_failed_when_result suppresses the existing exception
# for EVERY failed_when: evaluation, whatever the verdict).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("failed-when-suppressed-exception", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "failed_when suppressed-exception shape" do
  it "replaces the error text and exports the suppressed exception on a true verdict" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: command failure under a true failed_when
            ansible.builtin.command: /bin/false
            failed_when: true
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("[ERROR]: Task failed: Module failed: A 'failed_when' expression evaluated to 'True'.")
    output.must_include(%("failed_when_result": true))
    output.must_include(%("failed_when_suppressed_exception": "(traceback unavailable)"))
    # the module's own msg survives in the dump - only the exception (and
    # with it the [ERROR] block's text) was replaced
    output.must_include(%("msg": "The command exited with a non-zero return code."))
    output.wont_include("[Errno")
  end

  it "keeps a false verdict a success with the exception still suppressed" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: command failure suppressed by a false failed_when
            ansible.builtin.command: /bin/false
            failed_when: false
      YAML

    status.success?.must_equal(true)
    output.must_include("changed: [")
    output.wont_include("[ERROR]")
  end
end
