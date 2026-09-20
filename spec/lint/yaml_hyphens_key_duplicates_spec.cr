require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlHyphensRule do
    rule = YamlHyphensRule.new

    it "flags too many spaces after a hyphen" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    list:\n      -   a\n      - b\n")
      v.map(&.rule_id).should eq(["yaml[hyphens]"])
      v.first.line.should eq(6)
      v.first.message.should eq("Too many spaces after hyphen")
    end

    it "accepts single-space hyphens and non-indicator hyphens" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    cmd: echo a - b\n    list:\n      - a\n      - - b\n")
      v.should be_empty
    end

    it "ignores hyphens inside block scalars" do
      v = lint_yaml(rule, "---\n- name: t\n  shell: |\n    ls -   foo\n  hosts: all\n")
      v.should be_empty
    end
  end

  describe YamlKeyDuplicatesRule do
    rule = YamlKeyDuplicatesRule.new

    it "flags duplicated mapping keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    dup: 1\n    dup: 2\n")
      v.map(&.rule_id).should eq(["yaml[key-duplicates]"])
      v.first.line.should eq(6)
      v.first.message.should eq("Duplication of key \"dup\" in mapping")
    end

    it "flags duplicates in nested mappings but keeps distinct mappings separate" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a:\n      k: 1\n      k: 2\n    b:\n      k: 3\n")
      v.size.should eq(1)
      v.first.line.should eq(7)
    end

    it "exempts merge keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a: &base\n      k: 1\n    b:\n      <<: *base\n")
      v.should be_empty
    end

    it "accepts unique keys" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n")
      v.should be_empty
    end
  end
end
