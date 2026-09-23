require "../spec_helper"
require "../../src/krikri/conditional_evaluator"

describe Krikri::ConditionalEvaluator do
  # The filter-chain variant (`(x | combine({...})) == {...}`) needs the
  # full Crinja filter registry, only present in integration runs - it's
  # covered live by modules_data.yml's shapers assert.
  it "evaluates dict literal inequality" do
    Krikri::ConditionalEvaluator.evaluate(
      %q({'x': 'y'} != {'x': 'z'}), {} of String => JSON::Any
    ).should be_true
  end

  it "evaluates nested dict and list literal values" do
    Krikri::ConditionalEvaluator.evaluate(
      %q({'a': [1, 2], 'b': {'c': null}} == {'a': [1, 2], 'b': {'c': null}}), {} of String => JSON::Any
    ).should be_true
  end

  it "evaluates a bare dict literal comparison" do
    Krikri::ConditionalEvaluator.evaluate(
      %q({"x": "y"} == {"x": "y"}), {} of String => JSON::Any
    ).should be_true
  end
end
