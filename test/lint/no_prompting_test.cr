require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoPromptingRule do
    private def rule
      NoPromptingRule.new
    end

    private def playbook(tasks : String) : String
      "---\n- name: Play\n  hosts: all\n  tasks:\n#{tasks}"
    end

    it "flags a pause with no duration at the task's first line" do
      v = lint_yaml(rule, playbook(
        "    - name: Wait for the operator\n" \
        "      ansible.builtin.pause:\n" \
        "        prompt: \"Press enter to continue\"\n"))
      v.size.must_equal(1)
      violation = v.first
      violation.line.must_equal(5)
      violation.column.must_equal(0)
      violation.rule_id.must_equal("no-prompting")
      violation.message.must_equal("Disallow prompting.")
      violation.task_line.must_equal(5)
    end

    it "declares upstream's severity, tags and opt-in gate" do
      rule.severity.must_equal(Severity::VERY_LOW)
      rule.tags.must_equal(["opt-in"])
      rule.opt_in?.must_equal(true)
      rule.task_scoped?.must_equal(true)
    end

    it "treats a truthy duration as unattended" do
      v = lint_yaml(rule, playbook(
        "    - name: Seconds\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds: 5\n" \
        "    - name: Minutes\n" \
        "      ansible.builtin.pause:\n" \
        "        minutes: 1\n" \
        "    - name: Both\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds: 1\n" \
        "        minutes: 1\n"))
      v.must_be_empty
    end

    it "flags zero and empty durations, which still block on a prompt" do
      v = lint_yaml(rule, playbook(
        "    - name: Seconds zero\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds: 0\n" \
        "    - name: Minutes zero\n" \
        "      ansible.builtin.pause:\n" \
        "        minutes: 0\n" \
        "    - name: Bare\n" \
        "      ansible.builtin.pause:\n" \
        "    - name: Empty seconds\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds:\n" \
        "    - name: False seconds\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds: false\n"))
      v.map(&.line).must_equal([5, 8, 11, 13, 16])
    end

    # PyYAML keeps a quoted scalar a string, so "0" is truthy to
    # upstream's `or` test even though a plain 0 is the integer zero.
    it "keeps a quoted zero truthy like upstream" do
      v = lint_yaml(rule, playbook(
        "    - name: Quoted zero\n" \
        "      ansible.builtin.pause:\n" \
        "        seconds: \"0\"\n"))
      v.must_be_empty
    end

    # Upstream parses a free-form action with parse_kv, which leaves
    # every value a string: minutes=0 is the truthy string "0".
    it "treats a free-form duration as a non-empty string" do
      v = lint_yaml(rule, playbook(
        "    - name: Free form five\n" \
        "      pause: seconds=5\n" \
        "    - name: Free form zero\n" \
        "      pause: minutes=0\n"))
      v.must_be_empty
    end

    it "reads a duration from the task's args mapping" do
      v = lint_yaml(rule, playbook(
        "    - name: Args duration\n" \
        "      ansible.builtin.pause:\n" \
        "      args:\n" \
        "        seconds: 5\n"))
      v.must_be_empty
    end

    it "resolves the module an action directive names" do
      v = lint_yaml(rule, playbook(
        "    - name: Action directive\n" \
        "      action: pause\n" \
        "    - name: Action with duration\n" \
        "      action: pause seconds=5\n" \
        "    - name: Legacy pause is a different name\n" \
        "      ansible.legacy.pause:\n"))
      v.map(&.line).must_equal([5])
    end

    it "runs on a role's tasks file too" do
      v = lint_yaml(rule,
        "- name: Wait\n  ansible.builtin.pause:\n", FileType::TASKS)
      v.size.must_equal(1)
      v.first.line.must_equal(1)
    end

    it "is off by default and runs only when --enable-list names it" do
      yaml = playbook(
        "    - name: Wait\n" \
        "      ansible.builtin.pause:\n")
      rules = [rule] of Rule
      run_rules_yaml(yaml, rules).must_be_empty
      run_rules_yaml(yaml, rules,
        LintConfig.new(enable_list: ["no-prompting"])).size.must_equal(1)
      # Upstream's loader keys the opt-in gate on the rule id, never on
      # the tag.
      run_rules_yaml(yaml, rules,
        LintConfig.new(enable_list: ["opt-in"])).must_be_empty
      run_rules_yaml(yaml, rules,
        LintConfig.new(tags: ["opt-in"])).must_be_empty
    end

    it "is suppressed by a task-level noqa" do
      yaml = playbook(
        "    - name: Wait\n" \
        "      ansible.builtin.pause:\n" \
        "      when: false  # noqa: no-prompting\n")
      run_rules_yaml(yaml, [rule] of Rule,
        LintConfig.new(enable_list: ["no-prompting"])).must_be_empty
    end

    it "is registered for --list-rules" do
      registered = RuleRegistry.default.find("no-prompting")
      registered.wont_be_nil
      registered.try(&.severity).must_equal(Severity::VERY_LOW)
      registered.try(&.tags).must_equal(["opt-in"])
    end
  end
end
