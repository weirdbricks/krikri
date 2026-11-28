require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe AvoidImplicitRule do
    private def rule
      AvoidImplicitRule.new
    end

    # A task file rather than a play, so the task line is line 2 and the
    # fixture reads like the task YAML a role carries.
    private def task_yaml(module_line : String) : String
      "---\n- name: A task\n#{module_line}"
    end

    it "flags a copy task whose content is a mapping at the task line" do
      v = lint_yaml(rule, task_yaml(
        "  ansible.builtin.copy:\n" \
        "    content:\n" \
        "      a: b\n" \
        "    dest: /tmp/out.txt\n"), FileType::TASKS)
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("avoid-implicit")
      violation.line.must_equal(2)
      violation.column.must_equal(0)
      violation.message.must_equal("Avoid implicit behaviors")
      violation.task_line.must_equal(2)
    end

    it "flags a bare copy and a content list" do
      lint_yaml(rule, task_yaml(
        "  copy:\n" \
        "    content:\n" \
        "      - a\n" \
        "      - b\n" \
        "    dest: /tmp/out.txt\n"), FileType::TASKS).size.must_equal(1)
    end

    # Upstream compares the loaded Python value against str, so every
    # non-string scalar is flagged, null included: `content:` with no
    # value is None there.
    it "flags content that resolves to a non-string scalar" do
      %w[123 1.5 yes true null].each do |value|
        v = lint_yaml(rule, task_yaml(
          "  ansible.builtin.copy:\n" \
          "    content: #{value}\n" \
          "    dest: /tmp/out.txt\n"), FileType::TASKS)
        v.size.must_equal(1)
      end
      v = lint_yaml(rule, task_yaml(
        "  ansible.builtin.copy:\n" \
        "    content:\n" \
        "    dest: /tmp/out.txt\n"), FileType::TASKS)
      v.size.must_equal(1)
    end

    it "allows string content, templated or not" do
      [
        "    content: hello\n",
        "    content: \"{{ var }}\"\n",
        "    content: |\n      a: b\n",
        "    content: !!str 123\n",
      ].each do |line|
        lint_yaml(rule, task_yaml(
          "  ansible.builtin.copy:\n" \
          "#{line}" \
          "    dest: /tmp/out.txt\n"), FileType::TASKS).must_be_empty
      end
    end

    it "allows a copy task with no content" do
      lint_yaml(rule, task_yaml(
        "  ansible.builtin.copy:\n" \
        "    src: /tmp/in.txt\n" \
        "    dest: /tmp/out.txt\n"), FileType::TASKS).must_be_empty
    end

    it "flags content declared under args" do
      v = lint_yaml(rule, task_yaml(
        "  ansible.builtin.copy:\n" \
        "    dest: /tmp/out.txt\n" \
        "  args:\n" \
        "    content:\n" \
        "      a: b\n"), FileType::TASKS)
      v.size.must_equal(1)
    end

    it "flags the alias action forms that resolve to copy" do
      [
        "  action:\n    module: ansible.builtin.copy\n    content:\n      a: b\n    dest: /tmp/out.txt\n",
        "  local_action:\n    module: copy\n    content:\n      - a\n    dest: /tmp/out.txt\n",
      ].each do |task|
        lint_yaml(rule, task_yaml(task), FileType::TASKS).size.must_equal(1)
      end
    end

    it "does not flag ansible.legacy.copy, like upstream" do
      lint_yaml(rule, task_yaml(
        "  ansible.legacy.copy:\n" \
        "    content:\n" \
        "      a: b\n" \
        "    dest: /tmp/out.txt\n"), FileType::TASKS).must_be_empty
    end

    it "does not flag other modules with mapping arguments" do
      lint_yaml(rule, task_yaml(
        "  ansible.builtin.debug:\n" \
        "    msg:\n" \
        "      a: b\n"), FileType::TASKS).must_be_empty
    end

    it "is a task-scoped MEDIUM rule in the safety profile" do
      rule.severity.must_equal(Severity::MEDIUM)
      rule.tags.must_equal(["unpredictability"])
      rule.task_scoped?.must_equal(true)
      RuleRegistry.default.find("avoid-implicit").wont_be_nil
      Profile.of("avoid-implicit").must_equal("safety")
      Profile.includes?("safety", "avoid-implicit").must_equal(true)
      Profile.includes?("moderate", "avoid-implicit").must_equal(false)
    end
  end
end
