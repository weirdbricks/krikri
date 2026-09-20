require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlOctalValuesRule do
    rule = YamlOctalValuesRule.new

    it "flags plain implicit and explicit octal values" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    m1: 0644\n    m2: 0o644\n    m3: 012\n")
      v.map(&.rule_id).should eq(["yaml[octal-values]", "yaml[octal-values]", "yaml[octal-values]"])
      v[0].line.should eq(5)
      v[0].message.should eq("Forbidden implicit octal value \"0644\"")
      v[1].line.should eq(6)
      v[1].message.should eq("Forbidden explicit octal value \"0o644\"")
      v[2].line.should eq(7)
    end

    it "accepts quoted octal-looking strings, decimals and small zeros" do
      v = lint_yaml(rule, "---\n- name: t\n  hosts: all\n  vars:\n    a: \"0644\"\n    b: 644\n    c: 0\n    d: 089\n    e: '0o644'\n")
      v.should be_empty
    end
  end
end
