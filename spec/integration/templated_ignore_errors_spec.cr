require "../spec_helper"

# Regression spec for the actual bug behind round 76017's
# dj-wasabi.telegraf divergence: a templated `ignore_errors:` (the
# idiom's dominant real-world form is `ignore_errors: "{{
# ansible_check_mode }}"` - ignore failures only in --check mode) got a
# wrong parse-time guess (PlaybookParser.parse_ignore_errors defaults
# any templated value to TRUE), so on a normal (non-check) run a real
# task failure was silently swallowed and the play kept running past a
# point real Ansible halts at. TaskExecutor#resolve_task_ignore_errors
# re-renders the raw expression against the live vars context (which
# has ansible_check_mode bound) at every actual ignore-errors decision
# point, overriding the wrong guess.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(extra_args : Array(String)) : {Process::Status, String}
  playbook = File.tempname("templated-ignore-errors", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: fails for real
          ansible.builtin.fail:
            msg: real failure
          ignore_errors: "{{ ansible_check_mode }}"
        - name: after
          ansible.builtin.debug:
            msg: still running
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook] + extra_args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "templated ignore_errors: re-resolved at runtime, not parse time" do
  it "does NOT ignore a real failure on a normal run (ansible_check_mode is false)" do
    status, output = run_playbook([] of String)

    status.success?.should be_false, output
    output.should contain("real failure"), output
    output.should_not contain("still running"), output
    output.should_not contain("...ignoring"), output
  end

  it "DOES ignore the same failure under --check (ansible_check_mode is true)" do
    status, output = run_playbook(["--check"])

    status.success?.should be_true, output
    output.should contain("...ignoring"), output
    output.should contain("still running"), output
  end
end
