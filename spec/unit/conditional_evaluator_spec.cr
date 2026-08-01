require "../spec_helper"
require "../../src/crystal_play/conditional_evaluator"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

private EMPTY_VARS = Hash(String, JSON::Any).new

describe CrystalPlay::ConditionalEvaluator do
  describe "equality" do
    it "evaluates == true when values match" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_true
    end

    it "evaluates == false when values differ" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo == "bar"), v).should be_false
    end

    it "evaluates !=" do
      v = vars({"foo" => "baz"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate(%(foo != "bar"), v).should be_true
    end
  end

  describe "numeric comparisons" do
    it "evaluates <" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count < 5", v).should be_true
    end

    it "evaluates >" do
      v = vars({"count" => 3_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count > 5", v).should be_false
    end

    it "evaluates <=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count <= 5", v).should be_true
    end

    it "evaluates >=" do
      v = vars({"count" => 5_i64} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("count >= 6", v).should be_false
    end
  end

  describe "boolean operators" do
    it "evaluates 'and' requiring all parts true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("a and b", v).should be_false
    end

    it "evaluates 'or' requiring any part true" do
      v = vars({"a" => true, "b" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("a or b", v).should be_true
    end

    it "evaluates leading 'not'" do
      v = vars({"a" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("not a", v).should be_true
    end
  end

  describe "membership ('in')" do
    it "checks substring membership" do
      CrystalPlay::ConditionalEvaluator.evaluate(%("ba" in "bar"), EMPTY_VARS).should be_true
    end
  end

  describe "definedness" do
    it "evaluates 'is defined' true for present variables" do
      v = vars({"foo" => "bar"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("foo is defined", v).should be_true
    end

    it "evaluates 'is not defined' true for missing variables" do
      CrystalPlay::ConditionalEvaluator.evaluate("foo is not defined", EMPTY_VARS).should be_true
    end
  end

  describe "truthiness" do
    it "treats a bare true variable as truthy" do
      v = vars({"flag" => true} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("flag", v).should be_true
    end

    it "treats a bare false variable as falsy" do
      v = vars({"flag" => false} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("flag", v).should be_false
    end

    it "treats an undefined bare variable as falsy" do
      CrystalPlay::ConditionalEvaluator.evaluate("missing", EMPTY_VARS).should be_false
    end

    it "treats a non-empty string as truthy" do
      v = vars({"name" => "x"} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("name", v).should be_true
    end

    it "treats an empty string as falsy" do
      v = vars({"name" => ""} of String => JSON::Any::Type)
      CrystalPlay::ConditionalEvaluator.evaluate("name", v).should be_false
    end
  end
end
