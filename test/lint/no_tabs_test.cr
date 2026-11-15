require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoTabsRule do
    private def rule
      NoTabsRule.new
    end

    it "flags an escaped tab at the value's position" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.debug:\n        msg: \"a\\tb\"\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("no-tabs")
      v.first.line.must_equal(7)
      v.first.column.must_equal(14)
      v.first.message.must_equal("Most files should not contain tabs.")
    end

    it "flags a tab in a block scalar once, where the scalar starts" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.copy:\n        content: |\n          foo\n          \tbar\n        dest: /tmp/x\n")
      v.size.must_equal(1)
      v.first.line.must_equal(7)
      v.first.column.must_equal(18)
    end

    it "exempts the lineinfile options that take tabs" do
      yaml = "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.lineinfile:\n        path: /tmp/x\n        line: \"a\\tb\"\n        regexp: \"c\\td\"\n    - name: B\n      ansible.builtin.lineinfile:\n        path: \"/tmp/e\\tf\"\n        line: x\n"
      v = lint_yaml(rule, yaml)
      v.size.must_equal(1)
      v.first.line.must_equal(12)
      v.first.column.must_equal(15)
    end

    it "does not exempt a tab nested below an exempted option" do
      yaml = "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.lineinfile:\n        path: /tmp/x\n        line:\n          - \"a\\tb\"\n"
      v = lint_yaml(rule, yaml)
      v.size.must_equal(1)
      v.first.line.must_equal(9)
    end

    it "skips keys and values that contain jinja" do
      yaml = "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.debug:\n        msg: \"{{ x }}\\ty\"\n    - name: B\n      ansible.builtin.set_fact:\n        \"{{ y }}\\tz\": 1\n"
      lint_yaml(rule, yaml).must_be_empty
    end

    it "flags a key containing a tab at the key's position" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.set_fact:\n        \"a\\tb\": 1\n")
      v.size.must_equal(1)
      v.first.line.must_equal(7)
      v.first.column.must_equal(9)
    end

    it "scans block statements and their nested tasks like upstream" do
      yaml = "---\n- name: Play\n  hosts: all\n  tasks:\n    - block:\n        - name: nested\ttab\n          ansible.builtin.debug:\n            msg: hi\n      name: block\ttab\n"
      v = lint_yaml(rule, yaml)
      positions = v.map { |item| {item.line, item.column} }.sort!
      # The nested task's name is reached twice: once through the
      # enclosing block statement and once as a task of its own.
      positions.must_equal([{6, 17}, {6, 17}, {9, 13}])
    end
  end
end
