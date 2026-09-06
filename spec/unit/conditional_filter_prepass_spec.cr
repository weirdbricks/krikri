require "../spec_helper"
require "../../src/krikri/conditional_evaluator"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

private def empty_vars : Hash(String, JSON::Any)
  Hash(String, JSON::Any).new
end

# Compile-time filter-name validation in ConditionalEvaluator - a `when:`
# must hard-fail a filter name neither engine implements even when
# short-circuit evaluation never reaches the clause using it (real Jinja
# resolves every filter name in the whole expression at compile time).
# Found via jriguera.configdrive (round 20014): `when: X is defined and
# not X is none and Y|success and ...` with X undefined - `|success` is
# an Ansible 1.x filter removed from modern ansible-core, real Ansible
# fails with "Syntax error in expression: No filter named 'success'.",
# krikri silently skipped the task instead.
describe "ConditionalEvaluator compile-time filter-name validation" do
  it "raises for an unknown filter buried behind a short-circuited False clause" do
    v = vars({"Y" => "yes"})
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError, "No filter named 'success'") do
      Krikri::ConditionalEvaluator.evaluate("X is defined and not X is none and Y|success and Y", v)
    end
  end

  it "raises the same error when the clause IS reached (no behavior change there)" do
    v = vars({"Y" => "yes"})
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError, "No filter named 'success'") do
      Krikri::ConditionalEvaluator.evaluate("Y|success", v)
    end
  end

  it "still short-circuits normally when every referenced filter is known" do
    v = vars({"flag" => false, "Y" => "yes"})
    Krikri::ConditionalEvaluator.evaluate("flag and Y|d(1)", v).should be_false
  end

  it "ignores a | inside a quoted string literal" do
    v = vars({"x" => "a|b", "Y" => "c"})
    Krikri::ConditionalEvaluator.evaluate(%(x == 'a|b' and Y == "c"), v).should be_true
  end

  it "ignores a | inside a quoted match() regex argument" do
    v = vars({"x" => "hello"})
    # `bar` (and `foo`) are not real filter names - if the scanner read
    # the quoted "foo|bar" as a filter reference, this would raise.
    Krikri::ConditionalEvaluator.evaluate(%(false_flag and x is match("foo|bar")), v).should be_false
  end

  it "accepts an ansible.builtin.-prefixed filter name" do
    v = vars({"missing" => "fallback", "flag" => false})
    Krikri::ConditionalEvaluator.evaluate(%(flag and (missing | ansible.builtin.default('fallback') == 'fallback')), v).should be_false
  end

  it "accepts a Crinja-native filter name the hand-rolled engine lacks" do
    v = vars({"items" => [] of JSON::Any, "flag" => false})
    Krikri::ConditionalEvaluator.evaluate(%(flag and items|map('totally_bogus_inner')|list == []), v).should be_false
  end

  it "does not validate map()'s inner filter name (real Jinja resolves it at runtime)" do
    v = vars({"items" => [] of JSON::Any})
    Krikri::ConditionalEvaluator.evaluate("items|map('totally_bogus_inner')|list == []", v).should be_true
  end

  it "validates filters inside parenthesized sub-expressions too" do
    v = vars({"Y" => "yes"})
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError, "No filter named 'success'") do
      Krikri::ConditionalEvaluator.evaluate("(false and (Y|d(1))) or (Y|success)", v)
    end
  end
end

describe "FilterEngine::KNOWN_FILTER_NAMES registry" do
  it "contains no name the apply() dispatch no longer knows" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    Krikri::VariableSubstitutor::FilterEngine::KNOWN_FILTER_NAMES.each do |name|
      begin
        engine.apply(JSON::Any.new(nil), name)
      rescue ex : Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError
        raise "filter '#{name}' is listed in KNOWN_FILTER_NAMES but apply() raises UnknownFilterError for it"
      rescue
        # A type/argument error from feeding nil into a real filter is
        # fine - the name itself resolved, which is all this checks.
      end
    end
  end
end
