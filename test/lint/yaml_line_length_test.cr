require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlLineLengthRule do
    private def rule
      YamlLineLengthRule.new
    end

    it "flags a line longer than 160 characters" do
      long = "comment: " + ("x" * 200)
      v = lint_yaml(rule, "---\n#{long}\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("yaml[line-length]")
      v.first.line.must_equal(2)
      v.first.message.must_equal("Line too long (209 > 160 characters)")
    end

    it "allows lines up to 160 characters" do
      ok = "comment: " + ("x" * 151)
      v = lint_yaml(rule, "---\n#{ok}\n")
      v.must_be_empty
    end

    it "reports each long line with its number" do
      long = "a: " + ("x" * 170)
      v = lint_yaml(rule, "---\n#{long}\n#{long}\n")
      v.size.must_equal(2)
      v[0].line.must_equal(2)
      v[1].line.must_equal(3)
    end
  end
end
