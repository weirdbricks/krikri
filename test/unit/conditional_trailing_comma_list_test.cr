require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_filters"

# A trailing comma is legal Python/Jinja syntax for list (and dict) literals
# and yields no extra element. Both hand-rolled list-literal parsers kept the
# split(',') artifact instead: the ConditionalEvaluator looked the empty
# element up as a variable named '' and failed the whole conditional
# (`ansible_distribution in ['Debian', 'Ubuntu', ] and ...` - round 5250000,
# cans.package-install), and the ExpressionEvaluator's parse_literal_array
# appended a bogus null element. Behavior verified against ansible-core
# 2.19.11 locally before being encoded here.
describe "trailing comma in list literals (conditional_trailing_comma_list_test.cr)" do
  private def vars
    {
      "ansible_distribution"    => JSON::Any.new("Debian"),
      "pkginstall_cache_purge"  => JSON::Any.new(true),
      "d"                       => JSON.parse(%({"a": 1, "b": 2})),
    }
  end

  it "ignores a trailing comma in an `in` conditional's list operand" do
    Krikri::ConditionalEvaluator.evaluate(
      "ansible_distribution in ['Debian', 'Ubuntu', ] and pkginstall_cache_purge", vars
    ).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("ansible_distribution in ['Ubuntu', 'RedHat', ]", vars).must_equal(false)
  end

  it "ignores a trailing comma in an equality comparison against a list literal" do
    Krikri::ConditionalEvaluator.evaluate("d == {'a': 1, 'b': 2, }", vars).must_equal(true)
  end

  it "keeps quoted empty-string elements that are real elements" do
    Krikri::ConditionalEvaluator.evaluate("'' in ['', 'a', ]", vars).must_equal(true)
  end

  it "does not append a null element in the {{ }} expression path" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("['a', 'b', ] | length").must_equal("2")
    evaluator.evaluate("['a', 'b', ] | last").must_equal("b")
  end
end
