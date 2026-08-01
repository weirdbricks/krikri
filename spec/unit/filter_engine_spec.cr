require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/filter_engine"

describe CrystalPlay::VariableSubstitutor::FilterEngine do
  engine = CrystalPlay::VariableSubstitutor::FilterEngine.new

  it "applies default when value is empty" do
    engine.apply("", %(default('fallback'))).should eq("fallback")
  end

  it "applies default when value is 'undefined'" do
    engine.apply("undefined", %(default('fallback'))).should eq("fallback")
  end

  it "leaves non-empty values untouched by default" do
    engine.apply("present", %(default('fallback'))).should eq("present")
  end

  it "uppercases with upper" do
    engine.apply("hello", "upper").should eq("HELLO")
  end

  it "lowercases with lower" do
    engine.apply("HELLO", "lower").should eq("hello")
  end

  it "capitalizes with capitalize" do
    engine.apply("hello world", "capitalize").should eq("Hello world")
  end

  it "title-cases with title" do
    engine.apply("hello world", "title").should eq("Hello World")
  end

  it "trims whitespace with trim" do
    engine.apply("  hello  ", "trim").should eq("hello")
  end

  it "reports length" do
    engine.apply("hello", "length").should eq("5")
  end

  it "replaces substrings with replace" do
    engine.apply("hello world", %(replace('world', 'there'))).should eq("hello there")
  end

  it "returns the first element with split" do
    engine.apply("a,b,c", %(split(','))).should eq("a")
  end

  it "returns the value unchanged for an unknown filter" do
    engine.apply("hello", "mystery").should eq("hello")
  end
end
