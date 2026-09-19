require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlLineLengthRule do
    rule = YamlLineLengthRule.new

    it "flags a line longer than 160 characters" do
      long = "comment: " + ("x" * 200)
      v = lint_yaml(rule, "---\n#{long}\n")
      v.size.should eq(1)
      v.first.rule_id.should eq("yaml[line-length]")
      v.first.line.should eq(2)
      v.first.message.should eq("Line too long (209 > 160 characters)")
    end

    it "allows lines up to 160 characters" do
      ok = "comment: " + ("x" * 151)
      v = lint_yaml(rule, "---\n#{ok}\n")
      v.should be_empty
    end

    it "reports each long line with its number" do
      long = "a: " + ("x" * 170)
      v = lint_yaml(rule, "---\n#{long}\n#{long}\n")
      v.size.should eq(2)
      v[0].line.should eq(2)
      v[1].line.should eq(3)
    end
  end
end
