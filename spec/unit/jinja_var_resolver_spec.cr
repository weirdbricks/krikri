require "../spec_helper"
require "../../src/krikri/variable_substitutor"

private def resolver_for(vars : Hash(String, JSON::Any)) : Krikri::VariableSubstitutor::JinjaVarResolver
  Krikri::VariableSubstitutor::JinjaVarResolver.new(vars, Krikri::VarSubstitutor.new(vars: vars))
end

describe Krikri::VariableSubstitutor::JinjaVarResolver do
  it "re-templates a variable whose value is itself a template" do
    resolver = resolver_for({
      "base"    => JSON::Any.new("web"),
      "derived" => JSON::Any.new("{{ base }}-01"),
    })
    resolver.resolve("derived").try(&.raw).should eq("web-01")
  end

  it "resolves a template bottoming out at an unset name as undefined" do
    resolver = resolver_for({"password" => JSON::Any.new("{{ never_set }}")})
    resolver.resolve("password").try(&.raw).should be_a(KrikriJinja::Undefined)
  end

  it "supplies omit only when no real variable has that name" do
    resolver_for({} of String => JSON::Any).resolve("omit").try(&.raw).should eq(Krikri::OMIT_SENTINEL)
    resolver_for({"omit" => JSON::Any.new("mine")}).resolve("omit").try(&.raw).should eq("mine")
  end

  it "leaves unknown names to the engine" do
    resolver_for({} of String => JSON::Any).resolve("missing").should be_nil
  end

  it "exposes the scope as vars without nesting vars itself" do
    vars = resolver_for({"a" => JSON::Any.new(1_i64), "vars" => JSON::Any.new("x")}).resolve("vars")
    hash = vars.not_nil!.raw.as(Hash(String, KrikriJinja::AnyValue))
    hash.keys.should eq(["a"])
  end

  it "evaluates structured values through the renderer" do
    vars = {
      "items"  => JSON.parse(%(["a", "{{ omit }}", "b"])),
      "name"   => JSON::Any.new("{{ 'x' ~ suffix }}"),
      "suffix" => JSON::Any.new("1"),
    }
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(vars)
    renderer.evaluate_value!("[1, omit, 3]").should eq(JSON.parse("[1, 3]"))
    renderer.evaluate_value!("name").should eq(JSON::Any.new("x1"))
    renderer.evaluate_value!("never_set").should be_nil
    renderer.evaluate_value!(%q('V\1')).should eq(JSON::Any.new(%q(V\1)))
    Krikri::VariableSubstitutor::JinjaRenderer.new(vars, true)
      .evaluate_value!(%q('a\nb')).should eq(JSON::Any.new("a\nb"))
  end
end
