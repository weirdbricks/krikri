require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlEmptyLinesRule do
    rule = YamlEmptyLinesRule.new

    it "allows up to two blank lines inside the document" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n  vars:\n    a: 1\n")
      v.should be_empty
    end

    it "flags more than two blank lines inside the document" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n\n  vars:\n    a: 1\n")
      v.map(&.rule_id).should eq(["yaml[empty-lines]"])
      v.first.line.should eq(6)
      v.first.message.should eq("Too many blank lines (3 > 2)")
    end

    it "flags blank lines at the end of the file" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n")
      v.map(&.line).should eq([5])
      v.first.message.should eq("Too many blank lines (2 > 0)")
    end

    it "allows single trailing newline and clean files" do
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n").should be_empty
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n").should_not be_empty
    end
  end

  describe YamlNewLineAtEndOfFileRule do
    rule = YamlNewLineAtEndOfFileRule.new

    it "flags a file without trailing newline" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all")
      v.map(&.rule_id).should eq(["yaml[new-line-at-end-of-file]"])
      v.first.line.should eq(3)
      v.first.message.should eq("No new line character at the end of file")
    end

    it "accepts a file ending with a newline" do
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n").should be_empty
    end
  end
end
