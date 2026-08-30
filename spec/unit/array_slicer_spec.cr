require "../spec_helper"
require "../../src/krikri/variable_substitutor/array_slicer"

describe Krikri::VariableSubstitutor::ArraySlicer do
  it "slices the first N elements with [:n]" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c", "d", "e"]))
    slicer = Krikri::VariableSubstitutor::ArraySlicer.new(v)
    JSON.parse(slicer.slice("items[:3]")).as_a.map(&.as_s).should eq(["a", "b", "c"])
  end

  it "slices from index N to the end with [n:]" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c", "d", "e"]))
    slicer = Krikri::VariableSubstitutor::ArraySlicer.new(v)
    JSON.parse(slicer.slice("items[2:]")).as_a.map(&.as_s).should eq(["c", "d", "e"])
  end

  it "resolves a nested array before slicing" do
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"stdout_lines": ["l1", "l2", "l3"]}))
    slicer = Krikri::VariableSubstitutor::ArraySlicer.new(v)
    JSON.parse(slicer.slice("result.stdout_lines[:2]")).as_a.map(&.as_s).should eq(["l1", "l2"])
  end

  it "returns 'undefined' when the variable does not exist" do
    slicer = Krikri::VariableSubstitutor::ArraySlicer.new(Hash(String, JSON::Any).new)
    slicer.slice("missing[:2]").should eq("undefined")
  end
end
