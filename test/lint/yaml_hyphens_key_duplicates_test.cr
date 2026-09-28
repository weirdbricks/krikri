require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlHyphensRule do
    private def rule
      YamlHyphensRule.new
    end

    it "flags too many spaces after a hyphen" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    list:\n      -   a\n      - b\n")
      v.map(&.rule_id).must_equal(["yaml[hyphens]"])
      v.first.line.must_equal(6)
      v.first.message.must_equal("Too many spaces after hyphen")
    end

    it "accepts single-space hyphens and non-indicator hyphens" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    cmd: echo a - b\n    list:\n      - a\n      - - b\n")
      v.must_be_empty
    end

    it "ignores hyphens inside block scalars" do
      v = lint_yaml(rule, "---\n- name: t\n  shell: |\n    ls -   foo\n  hosts: all\n")
      v.must_be_empty
    end
  end

  describe YamlKeyDuplicatesRule do
    private def rule
      YamlKeyDuplicatesRule.new
    end

    it "flags duplicated mapping keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    dup: 1\n    dup: 2\n")
      v.map(&.rule_id).must_equal(["yaml[key-duplicates]"])
      v.first.line.must_equal(6)
      v.first.message.must_equal("Duplication of key \"dup\" in mapping")
    end

    it "flags duplicates in nested mappings but keeps distinct mappings separate" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a:\n      k: 1\n      k: 2\n    b:\n      k: 3\n")
      v.size.must_equal(1)
      v.first.line.must_equal(7)
    end

    it "exempts merge keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a: &base\n      k: 1\n    b:\n      <<: *base\n")
      v.must_be_empty
    end

    it "accepts unique keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n")
      v.must_be_empty
    end
  end
end
