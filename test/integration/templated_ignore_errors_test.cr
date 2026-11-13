require "../minitest_helper"

# Regression spec for the actual bug behind round 76017's
# dj-wasabi.telegraf divergence: a templated `ignore_errors:` (the
# idiom's dominant real-world form is `ignore_errors: "{{
# ansible_check_mode }}"` - ignore failures only in --check mode) got a
# wrong parse-time guess (PlaybookParser.parse_ignore_errors defaults
# any templated value to TRUE), so on a normal (non-check) run a real
# task failure was silently swallowed and the play kept running past a
# point Ansible halts at. TaskExecutor#resolve_task_ignore_errors
# re-renders the raw expression against the live vars context (which
# has ansible_check_mode bound) at every actual ignore-errors decision
# point, overriding the wrong guess.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(extra_args : Array(String)) : {Process::Status, String}
  playbook = File.tempname("templated-ignore-errors", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: fails for
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

    status.success?.must_equal(false, output)
    output.must_include("real failure", output)
    output.wont_include("still running", output)
    output.wont_include("...ignoring", output)
  end

  it "DOES ignore the same failure under --check (ansible_check_mode is true)" do
    status, output = run_playbook(["--check"])

    status.success?.must_equal(true, output)
    output.must_include("...ignoring", output)
    output.must_include("still running", output)
  end
end

private def run_when_ignore_playbook(yaml : String, extra_args : Array(String)) : {Process::Status, String}
  playbook = File.tempname("when-ignore-errors", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook] + extra_args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# ansible-core only honours `ignore_errors:` on a result whose attribute is
# already a real boolean (TaskContext._record_result's isinstance guard):
# a `when:`/loop-source evaluation failure raises BEFORE the task's
# keywords are post-validated, so a templated `ignore_errors: "{{
# ansible_check_mode }}"` there is never resolved and the failure stays
# fatal - live-verified vs 2.21.6, hwwilliams.epel under --check (issue
# #1227: real `failed=1 ignored=0`, krikri `ok=2 ... ignored=1` and ran
# the next task). A literal `ignore_errors: true` on the same task IS
# honoured (also live-verified), so only the templated form changes.
describe "templated ignore_errors: on a when: evaluation failure" do
  it "stays fatal under --check and halts the play (issue #1227)" do
    status, output = run_when_ignore_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: skipped stat seeds a dict register without stat
            ansible.builtin.stat:
              path: /nonexistent
            register: reg
            when: false
          - name: raising when under templated ignore_errors
            ansible.builtin.debug:
              msg: hi
            ignore_errors: "{{ ansible_check_mode }}"
            when:
              - not reg.stat.exists | bool
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    status.exit_code.must_equal(2, output)
    output.wont_include("still running", output)
    output.wont_include("...ignoring", output)
    output.must_match(/failed=1\b/, output)
    output.must_match(/ignored=0\b/, output)
  end

  it "does the same for a looped task's per-item when: failure" do
    status, output = run_when_ignore_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: skipped stat seeds a dict register without stat
            ansible.builtin.stat:
              path: /nonexistent
            register: reg
            when: false
          - name: raising when under templated ignore_errors
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: [1, 2]
            ignore_errors: "{{ ansible_check_mode }}"
            when:
              - not reg.stat.exists | bool
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    status.exit_code.must_equal(2, output)
    output.wont_include("still running", output)
    output.wont_include("...ignoring", output)
    output.must_match(/failed=1\b/, output)
    output.must_match(/ignored=0\b/, output)
  end
end
