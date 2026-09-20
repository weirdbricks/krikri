require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlIndentationRule do
    rule = YamlIndentationRule.new

    it "learns the indentation unit from the first next-line value" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a:\n      b: 1\n")
      v.should be_empty
    end

    it "flags over-indented nested values against the learned unit" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    x:\n        y: 1\n")
      v.map(&.rule_id).should eq(["yaml[indentation]"])
      v.first.line.should eq(6)
      v.first.message.should eq("Wrong indentation: expected 6 but found 8")
    end

    it "keeps the unit consistent across the file" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n      a: 1\n  tasks:\n    - name: Ok\n      ping: {}\n")
      v.map(&.rule_id).should eq(["yaml[indentation]"])
      v.first.line.should eq(7)
      v.first.message.should eq("Wrong indentation: expected 6 but found 4")
    end

    it "flags unindented sequences under a mapping key" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    pre:\n      x: 1\n    seq:\n    - a\n    - b\n")
      v.map(&.rule_id).should eq(["yaml[indentation]"])
      v.first.line.should eq(8)
      v.first.message.should eq("Wrong indentation: expected 6 but found 4")
    end

    it "reports expected-at-least for an unindented sequence before any unit is known" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n  - a\n  - b\n  tasks:\n    - name: Ok\n      ping: {}\n")
      v.map(&.line).should eq([5])
      v.first.message.should eq("Wrong indentation: expected at least 3")
    end

    it "flags a document that does not start at column 0" do
      v = lint_yaml(rule, "---\n   - a\n   - b\n")
      v.map(&.line).should eq([2])
      v.first.message.should eq("Wrong indentation: expected 0 but found 3")
      v = lint_yaml(rule, "  a: 1\n  b: 2\n")
      v.map(&.line).should eq([1])
      v.first.message.should eq("Wrong indentation: expected 0 but found 2")
    end

    it "ignores block scalar content and multi-line quoted scalars" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  shell: |\n      indented content\n  msg: \"multi\n      line\"\n")
      v.should be_empty
    end
  end
end
