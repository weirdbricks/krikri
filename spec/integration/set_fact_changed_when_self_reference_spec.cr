require "../spec_helper"
require "file_utils"

# Real Ansible evaluates a set_fact: task's own changed_when:/failed_when:
# against a context that already has the facts THAT SAME TASK just set
# merged in (the module result for set_fact carries them under
# ansible_facts, and that gets folded in before changed_when/failed_when
# templating). Found via smlloyd.authselect (RHEL-family round 60487):
# `set_fact: {authselect_current_profile: "{{ ... }}"}` with a
# `changed_when:` that references `authselect_current_profile` right back
# - real ansible-playbook resolves it fine; this engine raised
# "'authselect_current_profile' is undefined" because the caller only
# merges a set_fact's ansible_facts into vars_context AFTER
# apply_changed_failed_when returns.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "set_fact: changed_when: referencing a fact the same task just set" do
  it "resolves the just-set fact instead of raising undefined" do
    Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))
    playbook = File.join(PROJECT_ROOT, "spec", "tmp", "setfact-changed-when-self-ref.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        connection: local
        gather_facts: false
        tasks:
          - name: set a fact and key changed_when off it
            ansible.builtin.set_fact:
              current_value: "b"
            changed_when: current_value != "a"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook], output: output, error: output)
    captured = output.to_s

    status.success?.should be_true, captured
    captured.should_not contain("is undefined"), captured
    captured.should contain("changed: [localhost]"), captured
  end
end
