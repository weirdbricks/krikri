require "../spec_helper"
require "file_utils"

# Regression spec for the actual bug behind newrelic.newrelic-infra's
# invisible merge_yaml failure message: a templated `no_log:` (the
# idiom's dominant real-world form is a role default like
# `no_log: "{{ nrinfragent_hide_config_values }}"`, defaulting false)
# got the same wrong parse-time guess as ignore_errors: - Playbook
# Parser.parse_become_value defaults ANY templated value to true,
# which is the SAFE direction for this security control (never
# under-hides a real secret) but means the task's own failure message
# was suppressed on every run regardless of the actual value, hiding
# real errors from anyone debugging a failure.
#
# TaskExecutor#resolve_task_no_log re-renders the raw expression
# against the live vars context at every actual no_log decision point.
# Critically: an expression that CAN'T resolve against the given vars
# (the literal lenient-substitution sentinel "undefined") must fall
# back to the safe (hide-it) guess, not to evaluating that sentinel
# text as a boolean - verified separately that
# ConditionalEvaluator.evaluate("undefined", ...) returns false without
# raising, so a naive rescue-only safety net does NOT protect this.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_role_playbook(hide_it : String) : {Process::Status, String}
  root = File.tempname("templated-no-log")
  Dir.mkdir_p(File.join(root, "roles", "reprorole", "defaults"))
  Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
  File.write(File.join(root, "roles", "reprorole", "defaults", "main.yml"), "hide_it: #{hide_it}\n")
  File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
    - name: fails with templated no_log from a role default
      ansible.builtin.fail:
        msg: SECRET_SENTINEL_VALUE
      no_log: "{{ hide_it }}"
      ignore_errors: true
    YAML
  File.write(File.join(root, "pb.yml"), <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      roles:
        - reprorole
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(root) if root
end

describe "templated no_log: re-resolved at runtime, not parse time" do
  it "shows the failure message when the role-default no_log: resolves to false" do
    status, output = run_role_playbook("false")

    status.success?.should be_true, output
    output.should contain("SECRET_SENTINEL_VALUE"), output
  end

  it "hides the failure message when the role-default no_log: resolves to true" do
    # no_log: true suppresses EVERYTHING beyond the bare status line -
    # no msg, no "...ignoring" note either (that only prints on the
    # normal, non-no_log display path) - matching real Ansible's own
    # `failed: [host]` with nothing else leaked.
    status, output = run_role_playbook("true")

    status.success?.should be_true, output
    output.should_not contain("SECRET_SENTINEL_VALUE"), output
  end

  it "falls back to the safe (hide-it) guess when the expression can't resolve at all" do
    # A reference to a variable that's genuinely undefined anywhere
    # (not a role default, not a task-local vars: block, not a play
    # var) renders as the lenient-substitution sentinel "undefined" -
    # must degrade to the SAFE direction (hide), never accidentally
    # show a secret because resolution silently produced a falsy
    # non-boolean instead of raising.
    root = File.tempname("templated-no-log-unresolvable")
    Dir.mkdir_p(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unresolvable no_log expression (nothing defines hide_it_nowhere)
            ansible.builtin.fail:
              msg: SECRET_SENTINEL_VALUE
            no_log: "{{ hide_it_nowhere }}"
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.should be_true, output.to_s
    output.to_s.should_not contain("SECRET_SENTINEL_VALUE"), output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end
end
