require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

describe "Krikri::ConditionalEvaluator (conditional_newline_compare_test.cr)" do
  private def vars
    {
      "out" => JSON.parse(%q({"stdout": "line-one\nline-two"})),
    }
  end

  it "compares registered stdout containing a newline against a \\n literal" do
    Krikri::ConditionalEvaluator.evaluate(
      %q(out.stdout == 'line-one\nline-two'), vars
    ).must_equal(true)
  end
end

describe "Krikri::ConditionalEvaluator (conditional_newline_compare_test.cr: escape decoding)" do
  private def vars2
    {
      "out" => JSON.parse(%q({"stdout": "line-one\nline-two"})),
    }
  end

  it "compares stdout against a literal containing a REAL newline (YAML-decoded)" do
    condition = "out.stdout == 'line-one\nline-two'"
    Krikri::ConditionalEvaluator.evaluate(condition, vars2).must_equal(true)
  end

  it "decodes tab escapes in quoted literals" do
    vars3 = {"s" => JSON.parse(%q({"v": "a\tb"}))}
    Krikri::ConditionalEvaluator.evaluate(%q(s.v == 'a\tb'), vars3).must_equal(true)
  end

  it "decodes escaped backslashes and quotes in quoted literals" do
    vars4 = {"s" => JSON.parse(%q({"v": "a\\b'c\"d"}))}
    Krikri::ConditionalEvaluator.evaluate(%q(s.v == 'a\\b\'c\"d'), vars4).must_equal(true)
  end

  it "decodes hex escapes in quoted literals" do
    vars5 = {"s" => JSON.parse(%q({"v": "A"}))}
    Krikri::ConditionalEvaluator.evaluate(%q(s.v == '\x41'), vars5).must_equal(true)
  end

  it "keeps unknown escape sequences literal" do
    vars6 = {"s" => JSON.parse(%q({"v": "a\\db"}))}
    Krikri::ConditionalEvaluator.evaluate(%q(s.v == 'a\\db'), vars6).must_equal(true)
  end

  it "leaves literals without backslashes untouched" do
    Krikri::ConditionalEvaluator.evaluate(%q(out.stdout == 'plain'), vars2).must_equal(false)
  end
end
