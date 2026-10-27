require "../minitest_helper"

# A failed_when: that RAISES a non-boolean conditional error (e.g.
# `failed_when: r.stdout` with a non-empty string stdout) on a result the
# module did NOT itself fail is normalized by task_executor as an
# ACTION-level AnsibleActionCapturedError, not a module failure: the
# [ERROR] block reads "Task failed: Action failed." while the result JSON
# keeps the conditional error text in failed_when_result (live-verified
# vs ansible-core 2.19, issue #616). krikri used to classify it as
# "Module failed.".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "failed_when non-boolean error action shape" do
  it "classifies a raising failed_when on a healthy result as action-level, not Module failed" do
    playbook = File.tempname("failed-when-nonbool-action-shape", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: probe
            command:
              cmd: echo hi
            register: r
            failed_when: r.stdout
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Action failed.")
    text.wont_include("Module failed.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
