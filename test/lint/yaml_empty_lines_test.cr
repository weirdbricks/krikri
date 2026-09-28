require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlEmptyLinesRule do
    private def rule
      YamlEmptyLinesRule.new
    end

    it "allows up to two blank lines inside the document" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n  vars:\n    a: 1\n")
      v.must_be_empty
    end

    it "flags more than two blank lines inside the document" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n\n  vars:\n    a: 1\n")
      v.map(&.rule_id).must_equal(["yaml[empty-lines]"])
      v.first.line.must_equal(6)
      v.first.message.must_equal("Too many blank lines (3 > 2)")
    end

    it "flags blank lines at the end of the file" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n\n")
      v.map(&.line).must_equal([5])
      v.first.message.must_equal("Too many blank lines (2 > 0)")
    end

    it "allows single trailing newline and clean files" do
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n").must_be_empty
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n\n").wont_be_empty
    end
  end

  describe YamlNewLineAtEndOfFileRule do
    private def rule
      YamlNewLineAtEndOfFileRule.new
    end

    it "flags a file without trailing newline" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all")
      v.map(&.rule_id).must_equal(["yaml[new-line-at-end-of-file]"])
      v.first.line.must_equal(3)
      v.first.message.must_equal("No new line character at the end of file")
    end

    it "accepts a file ending with a newline" do
      lint_yaml(rule, "---\n- name: t\n  hosts: all\n").must_be_empty
    end
  end
end
