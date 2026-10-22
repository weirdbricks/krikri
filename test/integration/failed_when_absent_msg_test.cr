require "../minitest_helper"

# A failed_when:-failed result whose module left NO msg key finalizes
# through AnsibleActionCapturedError.normalize_result_exception, whose
# message defaults to "Unknown error." (live-verified vs ansible-playbook
# 2.19.11 with a stat on a missing path): the [ERROR] block reads
# "Task failed: Action failed: Unknown error." and the fatal dump carries
# the synthesized msg.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "failed_when absent-msg Unknown error shape" do
  it "synthesizes the Unknown error msg for a msg-less failed_when result" do
    playbook = File.tempname("failed-when-absent-msg", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: stat missing
            stat:
              path: /nonexistent-krikri-issue-227-probe
            failed_when: true
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
    text.must_include("\"msg\": \"Task failed: Action failed: Unknown error.\"")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
