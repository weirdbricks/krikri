require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlTrailingSpacesRule do
    rule = YamlTrailingSpacesRule.new

    it "flags lines with trailing whitespace" do
      v = lint_yaml(rule, "---\n- name: t  \n  hosts: all\n  vars:\n    msg: hello   \n")
      v.size.should eq(2)
      v[0].line.should eq(2)
      v[1].line.should eq(5)
      v.first.message.should eq("Trailing spaces")
    end

    it "accepts clean lines" do
      v = lint_yaml(rule, "---\n- name: t\n")
      v.should be_empty
    end
  end

  describe YamlTruthyRule do
    rule = YamlTruthyRule.new

    it "flags plain yes/no/on/off values" do
      v = lint_yaml(rule, "---\n- name: t\n  vars:\n    flag: yes\n    other: no\n    third: on\n    fourth: off\n")
      v.size.should eq(4)
      v.first.line.should eq(4)
      v.first.message.should eq("Truthy value should be one of [false, true]")
    end

    it "allows quoted values and real booleans" do
      v = lint_yaml(rule, "---\n- name: t\n  vars:\n    a: \"yes\"\n    b: true\n    c: false\n    d: 1\n")
      v.should be_empty
    end

    it "allows truthy-looking words inside longer strings" do
      v = lint_yaml(rule, "---\n- name: t\n  command: echo yes-please\n")
      v.should be_empty
    end
  end
end
