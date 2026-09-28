require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlTrailingSpacesRule do
    private def rule
      YamlTrailingSpacesRule.new
    end

    it "flags lines with trailing whitespace" do
      v = lint_yaml(rule, "---\n- name: t  \n  hosts: all\n  vars:\n    msg: hello   \n")
      v.size.must_equal(2)
      v[0].line.must_equal(2)
      v[1].line.must_equal(5)
      v.first.message.must_equal("Trailing spaces")
    end

    it "accepts clean lines" do
      v = lint_yaml(rule, "---\n- name: t\n")
      v.must_be_empty
    end
  end

  describe YamlTruthyRule do
    private def rule
      YamlTruthyRule.new
    end

    it "flags plain yes/no/on/off values" do
      v = lint_yaml(rule, "---\n- name: t\n  vars:\n    flag: yes\n    other: no\n    third: on\n    fourth: off\n")
      v.size.must_equal(4)
      v.first.line.must_equal(4)
      v.first.message.must_equal("Truthy value should be one of [false, true]")
    end

    it "allows quoted values and real booleans" do
      v = lint_yaml(rule, "---\n- name: t\n  vars:\n    a: \"yes\"\n    b: true\n    c: false\n    d: 1\n")
      v.must_be_empty
    end

    it "allows truthy-looking words inside longer strings" do
      v = lint_yaml(rule, "---\n- name: t\n  command: echo yes-please\n")
      v.must_be_empty
    end
  end
end
