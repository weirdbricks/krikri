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
    hash = vars.should_not(be_nil).raw.as(Hash(String, KrikriJinja::AnyValue))
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

  it "finds an integer-keyed dict entry whether the index is an int or a string" do
    # Real bug found benchmarking robertdebock.tomcat: its vars/main.yml
    # keys `_tomcat_unarchive_urls` by YAML integer (`7:`, `10:`), which
    # the var pipeline's JSON round trip flattens to plain string keys,
    # while `_tomcat_unarchive_urls[instance.version | default(...)]`
    # still indexes with the real integer - the engine's type-preserving
    # key encoding missed and the lookup silently rendered the literal
    # string "undefined", which then went out as a download URL. Real
    # Jinja2 matches dict keys by value, so the integer index must find
    # the entry; the string index keeps working too (it was the only
    # form that worked before), and an integer index must NOT start
    # matching a dict whose keys are genuinely non-numeric strings.
    vars = {
      "d"  => JSON.parse(%({"7": "seven", "10": "ten"})),
      "v"  => JSON::Any.new(10_i64),
      "d2" => JSON.parse(%({"a": "b"})),
    }
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(vars)
    renderer.evaluate_value!("d[v | default(10)]").should eq(JSON::Any.new("ten"))
    renderer.evaluate_value!("d[10]").should eq(JSON::Any.new("ten"))
    renderer.evaluate_value!("d['10']").should eq(JSON::Any.new("ten"))
    renderer.evaluate_value!("d2[10]").should be_nil
    renderer.evaluate_value!("d2['a']").should eq(JSON::Any.new("b"))
  end
end
