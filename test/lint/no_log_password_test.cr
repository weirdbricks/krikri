require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoLogPasswordRule do
    private def rule
      NoLogPasswordRule.new
    end

    private def playbook(task : String) : String
      "---\n- name: Play\n  hosts: all\n  tasks:\n#{task}"
    end

    private def fix_no_log_password_yaml(yaml : String, write_list = ["all"]) : String
      path = File.tempname("nologfix", ".yml")
      File.write(path, yaml)
      registry = RuleRegistry.new([NoLogPasswordRule.new] of Rule)
      file = PositionedFile.new(path, FileType::PLAYBOOK,
        YAML::Nodes.parse(yaml).nodes.first?, nil)
      violations = [] of Violation
      NoLogPasswordRule.new.check(file, violations)
      Fixer.new(registry, write_list).apply(violations)
      File.read(path)
    ensure
      File.delete(path) if path
    end

    it "flags a looped password task at the task line with no column" do
      v = lint_yaml(rule, playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n"))
      v.size.must_equal(1)
      violation = v.first
      violation.line.must_equal(5)
      violation.column.must_equal(0)
      violation.rule_id.must_equal("no-log-password")
      violation.message.must_equal("Password should not be logged.")
      violation.task_line.must_equal(5)
    end

    it "declares upstream's severity, tags and opt-in gate" do
      rule.severity.must_equal(Severity::LOW)
      rule.tags.must_equal(["autofix", "opt-in", "security", "experimental"])
      rule.opt_in?.must_equal(true)
      rule.task_scoped?.must_equal(true)
    end

    it "matches any argument name containing password, looped" do
      v = lint_yaml(rule, playbook(
        "    - name: url_password\n" \
        "      ansible.builtin.uri:\n" \
        "        url: \"{{ item }}\"\n" \
        "        url_password: s3cret\n" \
        "      with_items:\n" \
        "        - a\n" \
        "    - name: user_password\n" \
        "      example.user_module:\n" \
        "        user_password: \"{{ item }}\"\n" \
        "      with_random_choice:\n" \
        "        - a\n"))
      v.map(&.line).must_equal([5, 11])
    end

    # Upstream requires a loop: an unlooped password task is quiet, and so
    # are passwd/secret names because the match is on the substring
    # "password".
    it "stays quiet without a loop or without a password-named argument" do
      v = lint_yaml(rule, playbook(
        "    - name: Unlooped\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password: s3cret\n" \
        "    - name: passwd and secret\n" \
        "      ansible.builtin.set_fact:\n" \
        "        passwd: \"{{ item }}\"\n" \
        "        secret: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n"))
      v.must_be_empty
    end

    it "honours no_log's boolean values and never evaluates Jinja" do
      v = lint_yaml(rule, playbook(
        "    - name: true\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: &l\n" \
        "        - a\n" \
        "      no_log: true\n" \
        "    - name: yes\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "      no_log: yes\n" \
        "    - name: jinja\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "      no_log: \"{{ flag }}\"\n" \
        "    - name: false\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "      no_log: false\n" \
        "    - name: no\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "      no_log: no\n"))
      v.map(&.line).must_equal([21, 26])
    end

    # ansible.builtin.user's password_lock only suppresses the match when
    # the task has no password at all, and only for that exact module
    # name: a bare `user:` is not the FQCN upstream compares against, so
    # its password_lock argument is matched like any other.
    it "exempts only FQCN ansible.builtin.user with a truthy password_lock" do
      v = lint_yaml(rule, playbook(
        "    - name: fqcn lock\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password_lock: true\n" \
        "      loop: &l\n" \
        "        - a\n" \
        "    - name: bare lock\n" \
        "      user:\n" \
        "        name: x\n" \
        "        password_lock: true\n" \
        "      loop: *l\n" \
        "    - name: fqcn lock with password\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password_lock: true\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "    - name: fqcn falsy lock\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password_lock: false\n" \
        "      loop: *l\n" \
        "    - name: fqcn quoted lock\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "        password_lock: \"false\"\n" \
        "      loop: *l\n"))
      v.map(&.line).must_equal([11, 16, 22])
    end

    it "counts task-level args and free-form parameters" do
      v = lint_yaml(rule, playbook(
        "    - name: args mapping\n" \
        "      ansible.builtin.user:\n" \
        "        name: x\n" \
        "      args:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: &l\n" \
        "        - a\n" \
        "    - name: action directive\n" \
        "      action: user name=x password=y\n" \
        "      loop: *l\n" \
        "    - name: command free form\n" \
        "      ansible.builtin.command: echo password=x\n" \
        "      loop: *l\n"))
      v.map(&.line).must_equal([5, 12])
    end

    # Upstream's convert_to_boolean raises on an unrecognized no_log
    # value, and its runner discards every match matchtasks produced, so
    # one bad task silences the rule for the whole file.
    it "reports nothing for a file containing an unusable no_log value" do
      v = lint_yaml(rule, playbook(
        "    - name: fine\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: &l\n" \
        "        - a\n" \
        "    - name: unusable\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop: *l\n" \
        "      no_log: maybe\n"))
      v.must_be_empty
    end

    it "is off by default and runs only when --enable-list names it" do
      yaml = playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n")
      rules = [rule] of Rule
      run_rules_yaml(yaml, rules).must_be_empty
      run_rules_yaml(yaml, rules,
        LintConfig.new(enable_list: ["no-log-password"])).size.must_equal(1)
      run_rules_yaml(yaml, rules,
        LintConfig.new(enable_list: ["opt-in"])).must_be_empty
      run_rules_yaml(yaml, rules,
        LintConfig.new(tags: ["opt-in"])).must_be_empty
    end

    it "is a warning because the experimental tag is on the default warn list" do
      yaml = playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n")
      v = run_rules_yaml(yaml, [rule] of Rule,
        LintConfig.new(enable_list: ["no-log-password"]))
      v.size.must_equal(1)
      v.first.warning?.must_equal(true)
      v.first.level.must_equal("warning")
    end

    it "is suppressed by a task-level noqa" do
      yaml = playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n" \
        "      when: false  # noqa: no-log-password\n")
      run_rules_yaml(yaml, [rule] of Rule,
        LintConfig.new(enable_list: ["no-log-password"])).must_be_empty
    end

    it "appends no_log: true to a task that has none" do
      yaml = playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n")
      fix_no_log_password_yaml(yaml).must_equal(yaml + "      no_log: true\n")
    end

    it "rewrites a falsy no_log in place instead of appending a duplicate" do
      yaml = playbook(
        "    - name: Looped\n" \
        "      ansible.builtin.user:\n" \
        "        password: \"{{ item }}\"\n" \
        "      loop:\n" \
        "        - a\n" \
        "      no_log: false\n")
      fixed = fix_no_log_password_yaml(yaml)
      fixed.must_equal(yaml.sub("no_log: false", "no_log: true"))
      fixed.scan("no_log").size.must_equal(1)
    end

    it "is registered for --list-rules and the tag listing" do
      registry = RuleRegistry.default
      registered = registry.find("no-log-password")
      registered.wont_be_nil
      registered.try(&.tags).must_equal(["autofix", "opt-in", "security", "experimental"])
    end
  end
end
