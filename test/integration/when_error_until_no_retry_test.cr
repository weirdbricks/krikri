require "../minitest_helper"

# A `when:` conditional-EVALUATION error on an `until:`/`retries:` task is
# real's no-retry fatal: ansible-core evaluates `when:` BEFORE the attempt
# loop starts (task_executor.py's _execute_internal raises out of the
# conditional check, the for-attempt loop comes later), so the error
# escapes the loop entirely - one fatal, no "FAILED - RETRYING" lines and
# no attempts key on the result. krikri used to convert the raise to a
# failed result inside execute_task_once and let the until loop treat it
# as an ordinary failed attempt, printing three retry lines real never
# does (issue #547, lean_delivery.gitlab_runner's "Register gitlab-runner").
#
# The strict non-boolean message itself must also carry real's lineage
# clause: a failing COMPOUND clause of a when: LIST
# (`gitlab_ci_token | length` -> int) is labeled with that clause's own
# value-token position in the task file, both in the [ERROR] line and the
# "caused by" block - the joined when_condition string matches no list
# item, so the locator needs the remembered failing clause (issue #547).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(playbook : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
end

describe "when: evaluation error on an until: task" do
  it "fails on the first pass without retrying, like real's pre-loop conditional check" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          gitlab_runner_skip_registration: false
          gitlab_ci_token: ""
        tasks:
          - name: Register gitlab-runner
            command: /bin/true
            register: gitlab_runner
            until:
              - gitlab_runner.runner.active is defined
              - gitlab_runner.runner.active | bool
            when:
              - not gitlab_runner_skip_registration|bool
              - gitlab_ci_token | length
            no_log: true
      YAML

    status, output = run_playbook(playbook)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    # real labels the failing clause's own token (line 16 col 11 in this
    # playbook - the `gitlab_ci_token | length` item), not the when: key.
    output.must_match(/Conditional result \(False\) was derived from value of type 'int' at '[^']+:\d+:\d+'\. Conditionals must have a boolean result\./)
    output.must_include("fatal: [localhost]: FAILED! => {\"censored\": \"the output has been hidden due to the fact that 'no_log: true' was specified for this result\", \"changed\": false}")
    # The until attempt loop never engages: no retry callback lines, and
    # the fatal result carries no attempts key.
    output.wont_include("FAILED - RETRYING")
    output.wont_include("attempts")
    output.must_include("failed=1")
  end

  it "labels the failing when: list clause's own token position in the lineage clause" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          skip: false
          token: ""
        tasks:
          - name: gated task
            command: /bin/true
            when:
              - not skip|bool
              - token | length
      YAML

    status, output = run_playbook(playbook)

    status.success?.must_equal(false)
    # The failing clause `token | length` sits on the `when:` list item
    # line 12, column 11 - the same position real's caused-by Origin
    # already pins, now also inside the message's `at '...'` clause.
    location = "#{File.expand_path(playbook)}:12:11"
    output.must_include("Conditional result (False) was derived from value of type 'int' at '#{location}'. Conditionals must have a boolean result.")
    output.must_include("Conditional result (False) was derived from value of type 'int' at '#{location}'. Conditionals must have a boolean result.\nOrigin: #{location}")
  end
end
