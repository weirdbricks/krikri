require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyShellPipeRule do
    private def rule
      RiskyShellPipeRule.new
    end

    it "flags shell pipes without pipefail" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.message.must_equal("Shells that use pipes should set the pipefail option.")
    end

    it "allows pipefail" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: set -o pipefail && cat x | grep y\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "ignores double pipes and jinja filters" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cmd1 || cmd2\n    - name: B\n      shell: echo {{ \"x\" | upper }}\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "exempts tasks whose ignore_errors is truthy" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: true\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: yes\n    - name: C\n      shell: cat x | grep y\n      ignore_errors: 1\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "still flags falsey ignore_errors" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: false\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: no\n    - name: C\n      shell: cat x | grep y\n      ignore_errors: 0\n    - name: D\n      shell: cat x | grep y\n", FileType::PLAYBOOK)
      v.size.must_equal(4)
    end

    it "exempts quoted and templated ignore_errors like Python truthiness" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: \"false\"\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: \"{{ ie }}\"\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe IgnoreErrorsRule do
    private def rule
      IgnoreErrorsRule.new
    end

    it "flags truthy ignore_errors without register" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: true\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.message.must_include("Use failed_when and specify error conditions")
    end

    it "allows ignore_errors with register" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: true\n      register: r\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "allows false ignore_errors" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: false\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe RunOnceRule do
    it "flags run_once tasks and strategy free plays" do
      rule = RunOnceRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  strategy: free\n  tasks:\n    - name: A\n      command: ls\n      run_once: true\n", FileType::PLAYBOOK)
      v.map(&.rule_id).sort!.must_equal(["run-once[play]", "run-once[task]"])
    end

    it "ignores false run_once" do
      rule = RunOnceRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      run_once: false\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe LatestRule do
    it "flags git without version" do
      rule = LatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      git:\n        repo: https://x\n", FileType::PLAYBOOK)
      v.map(&.rule_id).must_equal(["latest[git]"])
      v.first.message.must_equal("Result of the command may vary on subsequent runs.")
    end

    it "allows pinned versions" do
      rule = LatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      git:\n        repo: https://x\n        version: v1.0\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe PackageLatestRule do
    it "flags state latest without version" do
      rule = PackageLatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      apt:\n        name: htop\n        state: latest\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.message.must_equal("Package installs should not use latest.")
    end

    it "allows present and versioned installs" do
      rule = PackageLatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      apt:\n        name: htop\n        state: present\n    - name: B\n      apt:\n        name: htop\n        state: latest\n        version: 1.0\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe LiteralCompareRule do
    private def rule
      LiteralCompareRule.new
    end

    it "flags comparisons to literal True/False at the task line" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: eq\n      when: flag == True\n    - name: B\n      debug:\n        msg: ne\n      when: flag != False\n", FileType::PLAYBOOK)
      v.size.must_equal(2)
      v.map(&.line).must_equal([5, 9])
      v.each { |violation| violation.column.must_equal(0) }
      v.first.message.must_equal("Don't compare to literal True/False.")
    end

    it "accepts lowercase literals" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: eq\n      when: flag == true\n    - name: B\n      debug:\n        msg: ne\n      when: flag != false\n", FileType::PLAYBOOK)
      v.size.must_equal(2)
    end

    it "reports the block and the nested task, like upstream's nested walk" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: Block\n      block:\n        - name: Inner\n          debug:\n            msg: inner\n          when: flag == True\n", FileType::PLAYBOOK)
      v.map(&.line).must_equal([5, 7])
    end

    it "flags any list item matching a literal" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: list\n      when:\n        - flag\n        - flag != False\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
    end

    it "allows plain conditions and non-literal comparisons" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: plain\n      when: flag\n    - name: B\n      debug:\n        msg: other\n      when: flag == other\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end

  describe EmptyStringCompareRule do
    private def rule
      EmptyStringCompareRule.new
    end

    it "flags comparisons to empty string at the task line" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: eq\n      when: var == \"\"\n    - name: B\n      debug:\n        msg: ne\n      when: var != \"\"\n", FileType::PLAYBOOK)
      v.size.must_equal(2)
      v.map(&.line).must_equal([5, 9])
      v.each { |violation| violation.column.must_equal(0) }
      v.first.message.must_equal("Don't compare to empty string.")
    end

    it "accepts single quotes and a missing space" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: sq\n      when: var == ''\n    - name: B\n      debug:\n        msg: nospace\n      when: var!=\"\"\n", FileType::PLAYBOOK)
      v.map(&.line).must_equal([5, 9])
    end

    it "reports the block and the nested task, like upstream's nested walk" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: Block\n      block:\n        - name: Inner\n          debug:\n            msg: inner\n          when: var == \"\"\n", FileType::PLAYBOOK)
      v.map(&.line).must_equal([5, 7])
    end

    it "flags any list item comparing to empty string" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: list\n      when:\n        - var\n        - var != \"\"\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
    end

    it "allows plain conditions and real comparisons" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: plain\n      when: var\n    - name: B\n      debug:\n        msg: other\n      when: var == \"x\"\n    - name: C\n      debug:\n        msg: bool\n      when: true\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "declares upstream's severity, tags and opt-in gate" do
      rule.severity.must_equal(Severity::HIGH)
      rule.tags.must_equal(["idiom", "opt-in"])
      rule.opt_in?.must_equal(true)
      rule.task_scoped?.must_equal(true)
    end

    it "stays off until --enable-list names it" do
      yaml = "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      debug:\n        msg: eq\n      when: var == \"\"\n"
      rules = [EmptyStringCompareRule.new] of Rule
      run_rules_yaml(yaml, rules).must_be_empty
      enabled = run_rules_yaml(yaml, rules,
        LintConfig.new(enable_list: ["empty-string-compare"]))
      enabled.size.must_equal(1)
      enabled.first.line.must_equal(5)
    end

    it "is registered for --list-rules" do
      registered = RuleRegistry.default.find("empty-string-compare")
      raise "empty-string-compare is not registered" unless registered
      registered.tags.must_equal(["idiom", "opt-in"])
    end
  end

  describe DeprecatedLocalActionRule do
    private def rule
      DeprecatedLocalActionRule.new
    end

    it "flags both written forms once per task, at the task line" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: mapping form\n      local_action:\n" \
                          "        module: debug\n        msg: hi\n" \
                          "    - name: string form\n      local_action: debug msg=hi\n")
      v.map { |x| {x.line, x.column} }.must_equal([{4, 0}, {8, 0}])
      v.first.message.must_equal(
        "Do not use 'local_action', use 'delegate_to: localhost'.")
    end

    it "leaves the newer action directive alone" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      action: debug msg=hi\n")
      v.must_be_empty
    end

    it "declares upstream's severity, tags and autofix support" do
      rule.severity.must_equal(Severity::MEDIUM)
      rule.tags.must_equal(["autofix", "deprecations"])
      rule.task_scoped?.must_equal(true)
      rule.fixable?.must_equal(true)
      v = Violation.new("p.yml", 1, 0, rule.id, rule.severity,
        DeprecatedLocalActionRule::MESSAGE)
      rule.marks_fixed?(v).must_equal(true)
    end

    it "is registered for --list-rules" do
      registered = RuleRegistry.default.find("deprecated-local-action")
      raise "deprecated-local-action is not registered" unless registered
      registered.severity.must_equal(Severity::MEDIUM)
      registered.tags.must_equal(["autofix", "deprecations"])
    end
  end
end
