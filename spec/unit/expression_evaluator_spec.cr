require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/expression_evaluator"

describe CrystalPlay::VariableSubstitutor::ExpressionEvaluator do
  it "dispatches simple lookups" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("ada")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("name").should eq("ada")
  end

  it "dispatches nested lookups" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("user.name").should eq("ada")
  end

  it "dispatches indexed access" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[0]").should eq("a")
  end

  it "dispatches comparisons before filters" do
    v = Hash(String, JSON::Any).new
    v["rc"] = JSON::Any.new(0_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("rc == 0").should eq("true")
  end

  it "applies a filter to a simple variable" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(missing | default('fallback'))).should eq("fallback")
  end
end
