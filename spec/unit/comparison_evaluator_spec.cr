require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/comparison_evaluator"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

describe CrystalPlay::VariableSubstitutor::ComparisonEvaluator do
  it "evaluates == against a variable and a literal" do
    v = vars({"rc" => 0_i64} of String => JSON::Any::Type)
    evaluator = CrystalPlay::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("rc == 0").should eq("true")
  end

  it "evaluates numeric < across variables" do
    v = vars({"count" => 3_i64} of String => JSON::Any::Type)
    evaluator = CrystalPlay::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("count < 5").should eq("true")
  end

  it "evaluates nested variable access (result.rc)" do
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"rc": 1}))
    evaluator = CrystalPlay::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("result.rc == 1").should eq("true")
  end

  it "returns false when neither side is a recognized operator" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("no operator here").should eq("false")
  end
end
