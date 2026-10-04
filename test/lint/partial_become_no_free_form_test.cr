require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe PartialBecomeRule do
    private def rule
      PartialBecomeRule.new
    end

    it "flags become_user with no become at the same level" do
      v = lint_yaml(rule, "---\n- hosts: all\n  become: true\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls\n" \
                          "      become_user: root\n")
      v.map(&.rule_id).must_equal(["partial-become[task]"])
      v.first.line.must_equal(5)
      v.first.message.must_include("``become_user`` should have a corresponding ``become``")
    end

    it "accepts become_user alongside become in the same task" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls\n" \
                          "      become: true\n      become_user: root\n")
      v.must_be_empty
    end

    it "flags a play carrying become_user with no become" do
      v = lint_yaml(rule, "---\n- hosts: all\n  become_user: root\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls\n")
      v.map(&.rule_id).must_equal(["partial-become[play]"])
      v.first.line.must_equal(2)
    end

    it "does not flag a become inherited from the play" do
      v = lint_yaml(rule, "---\n- hosts: all\n  become: true\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls\n" \
                          "      become_user: root\n      become: true\n")
      v.must_be_empty
    end
  end

  describe NoFreeFormRule do
    private def rule
      NoFreeFormRule.new
    end

    it "flags a free-form module call" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.get_url: url=http://x/ mode=0644\n")
      v.map(&.rule_id).must_equal(["no-free-form"])
      v.first.message.must_equal(
        "Avoid using free-form when calling module actions. (ansible.builtin.get_url)")
    end

    it "accepts the explicit mapping form" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.get_url:\n" \
                          "        url: http://x/\n        mode: \"0644\"\n")
      v.must_be_empty
    end

    it "accepts a plain command line with no key= option" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls -la /tmp\n")
      v.must_be_empty
    end

    it "flags a command carrying a module option in free form" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.command: ls chdir=/tmp\n")
      v.map(&.rule_id).must_equal(["no-free-form"])
    end

    it "exempts include and import actions" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.include_tasks: other.yml tags=a=b\n")
      v.must_be_empty
    end

    it "exempts a scalar module value with no equals sign" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n" \
                          "    - name: t\n      ansible.builtin.ping:\n")
      v.must_be_empty
    end
  end
end
