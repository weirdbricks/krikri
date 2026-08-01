require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/variable_lookup"

describe CrystalPlay::VariableSubstitutor::VariableLookup do
  it "resolves a simple string variable and strips whitespace" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("  hello  ")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.simple("name").should eq("hello")
  end

  it "returns 'undefined' for a missing simple variable" do
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(Hash(String, JSON::Any).new)
    lookup.simple("missing").should eq("undefined")
  end

  it "resolves nested hash access" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.name").should eq("ada")
  end

  it "returns 'undefined' for a missing nested key" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.email").should eq("undefined")
  end

  it "resolves numeric array indexing" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("items[1]").should eq("b")
  end

  it "resolves quoted hash key indexing" do
    v = Hash(String, JSON::Any).new
    v["config"] = JSON.parse(%({"host": "example.com"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed(%(config['host'])).should eq("example.com")
  end
end
