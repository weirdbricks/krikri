require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe OnlyBuiltinsRule do
    private def rule
      OnlyBuiltinsRule.new
    end

    private def playbook(task : String) : String
      "---\n- name: Play\n  hosts: all\n  tasks:\n#{task}"
    end

    it "flags a collection module at the task's first key line" do
      v = lint_yaml(rule, playbook(
        "    - name: Configure a sysctl\n" \
        "      ansible.posix.sysctl:\n" \
        "        name: kernel.pid_max\n"))
      v.size.must_equal(1)
      violation = v.first
      violation.line.must_equal(5)
      violation.column.must_equal(0)
      violation.rule_id.must_equal("only-builtins")
      violation.message.must_equal("Use only builtin actions.")
      violation.task_line.must_equal(5)
    end

    it "declares upstream's severity, tags and opt-in gate" do
      rule.severity.must_equal(Severity::MEDIUM)
      rule.tags.must_equal(["opt-in", "experimental"])
      rule.opt_in?.must_equal(true)
      rule.task_scoped?.must_equal(true)
    end

    it "allows ansible.builtin and ansible.legacy actions" do
      v = lint_yaml(rule, playbook(
        "    - name: Builtin\n" \
        "      ansible.builtin.debug:\n" \
        "        msg: hi\n" \
        "    - name: Legacy\n" \
        "      ansible.legacy.command: echo hi\n"))
      v.must_be_empty
    end

    it "allows upstream's bare builtin names" do
      v = lint_yaml(rule, playbook(
        "    - name: Bare builtin\n" \
        "      debug:\n" \
        "        msg: hi\n" \
        "    - name: Include\n" \
        "      include_role:\n" \
        "        name: foo\n"))
      v.must_be_empty
    end

    # Upstream compares the action name against fqcn.py's fixed builtins
    # list, so a builtin alias newer than that list is still reported.
    it "flags a builtin alias upstream's list does not carry" do
      v = lint_yaml(rule, playbook(
        "    - name: Newer alias\n" \
        "      systemd_service:\n" \
        "        name: foo\n"))
      v.size.must_equal(1)
    end

    it "resolves the module an action directive names" do
      v = lint_yaml(rule, playbook(
        "    - name: Collection via action\n" \
        "      action: ansible.posix.sysctl name=kernel.pid_max\n" \
        "    - name: Builtin via action\n" \
        "      action: debug msg=hi\n" \
        "    - name: Collection via local_action\n" \
        "      local_action: ansible.posix.sysctl name=kernel.pid_max\n"))
      v.map(&.line).must_equal([5, 9])
    end

    it "resolves a mapping-form action directive" do
      v = lint_yaml(rule, playbook(
        "    - name: Mapping form\n" \
        "      action:\n" \
        "        module: ansible.posix.sysctl\n" \
        "        name: kernel.pid_max\n"))
      v.size.must_equal(1)
      v.first.line.must_equal(5)
    end

    # Upstream exempts a nested task (the block statement itself) while
    # still checking the tasks inside it.
    it "exempts block parents but checks nested tasks" do
      v = lint_yaml(rule, playbook(
        "    - name: A block\n" \
        "      block:\n" \
        "        - name: Collection child\n" \
        "          community.general.ufw:\n" \
        "            state: disabled\n" \
        "        - name: Builtin child\n" \
        "          ansible.builtin.debug:\n" \
        "            msg: hi\n"))
      v.size.must_equal(1)
      v.first.line.must_equal(7)
    end

    it "is off by default and runs only when --enable-list names it" do
      yaml = playbook(
        "    - name: Configure a sysctl\n" \
        "      ansible.posix.sysctl:\n" \
        "        name: kernel.pid_max\n")
      runner_rules = [rule] of Rule
      run_rules_yaml(yaml, runner_rules).must_be_empty
      run_rules_yaml(yaml, runner_rules,
        LintConfig.new(enable_list: ["only-builtins"])).size.must_equal(1)
      # Upstream's loader keys the opt-in gate on the rule id, never on
      # the tag.
      run_rules_yaml(yaml, runner_rules,
        LintConfig.new(enable_list: ["opt-in"])).must_be_empty
      run_rules_yaml(yaml, runner_rules,
        LintConfig.new(tags: ["opt-in"])).must_be_empty
    end

    it "is suppressed by a task-level noqa" do
      yaml = playbook(
        "    - name: Configure a sysctl\n" \
        "      ansible.posix.sysctl:\n" \
        "        name: kernel.pid_max\n" \
        "      when: false  # noqa: only-builtins\n")
      run_rules_yaml(yaml, [rule] of Rule,
        LintConfig.new(enable_list: ["only-builtins"])).must_be_empty
    end

    it "is registered for --list-rules and the tag listing" do
      registry = RuleRegistry.default
      registered = registry.find("only-builtins")
      registered.wont_be_nil
      registered.try(&.tags).must_equal(["opt-in", "experimental"])
    end
  end
end
