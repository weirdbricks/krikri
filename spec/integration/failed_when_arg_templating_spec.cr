require "../spec_helper"
require "file_utils"

# Real bug found against real dirless-infra production playbooks: a task
# whose ARGUMENT templating fails (e.g. `"dirless-backend@{{ customer_name
# }}"` with customer_name undefined) failed BEFORE the module ever ran,
# but the resulting error was funneled through the same
# apply_changed_failed_when pipeline as a genuine module result - so
# `failed_when: false` swallowed it, the task reported `ok:` (with the
# fatal error text nested under it), and the play continued to the next
# task. Real Ansible (verified live against ansible-core 2.19.11) treats
# arg finalization as unconditionally fatal: `failed_when: false` has no
# effect, the host reports `fatal:` and stops. ignore_errors: DOES still
# apply (real Ansible: ignored=1, play continues).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "an arg-templating failure is unignorable by failed_when:" do
  it "fails the task and halts the play even with failed_when: false set" do
    playbook = File.tempname("failed-when-arg-templating", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: arg templating fails
            file:
              path: "/tmp/krikri-spec-{{ undefined_var_xyz }}"
              state: touch
            failed_when: false
          - name: should never run
            debug:
              msg: SHOULD_NOT_RUN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'undefined_var_xyz' is undefined")
    output.to_s.should_not contain("ok: [")
    output.to_s.should_not contain("SHOULD_NOT_RUN")
    output.to_s.should match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still honors ignore_errors: true (real Ansible: ignored=1, play continues)" do
    playbook = File.tempname("failed-when-arg-templating-ignore", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: arg templating fails, ignored
            file:
              path: "/tmp/krikri-spec-{{ undefined_var_xyz }}"
              state: touch
            ignore_errors: true
          - name: next task
            debug:
              msg: NEXT_TASK_RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("NEXT_TASK_RAN")
    output.to_s.should match(/ignored=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
