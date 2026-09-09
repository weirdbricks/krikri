require "../spec_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/conditional_evaluator"

# An unknown/unimplemented filter name must hard-fail at the point of the
# filter call with real Jinja2/Ansible's own wording ("No filter named
# 'X'.", a real TemplateAssertionError - Jinja validates filter names
# against its registered filter set and refuses to even attempt the call),
# never silently fall through to a placeholder. Found via nephelaiio.pip /
# nephelaiio.gitlab's own `nephelaiio.plugins.sorted_get`: the evaluator's
# raise was swallowed by the task-vars render's raise-to-absent rescue, the
# `vars:` entry got dropped, and the downstream
# `pip_packages | default(_pip_packages_default)` chain resolved to the
# literal text "undefined" - `apt install undefined`.
describe "unknown filter names hard-fail at the point of the call" do
  vars = {
    "pkg" => JSON::Any.new("nginx"),
    "lst" => JSON.parse(%(["a", "b"])),
    "ovr" => JSON.parse(%(["default"])),
  } of String => JSON::Any
  sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h")

  it "raises for a bare unknown filter in a {{ }} substitution" do
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'totally_bogus_filter_xyz'.") do
      sub.substitute(%({{ 5 | totally_bogus_filter_xyz }}))
    end
  end

  it "raises for a collection-qualified unknown filter, naming the full FQCN" do
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'nephelaiio.plugins.sorted_get'.") do
      sub.substitute(%({{ pkg | nephelaiio.plugins.sorted_get }}))
    end
  end

  it "raises (not falls through to undefined) when the unknown filter's own error is rescued by a default() fallback" do
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'nephelaiio.plugins.sorted_get'.") do
      sub.substitute(%({{ pkg | nephelaiio.plugins.sorted_get(ovr) | default('fallback') }}))
    end
  end

  it "still evaluates implemented filters through the same path" do
    sub.substitute(%({{ pkg | upper }})).should eq("NGINX")
    sub.substitute(%({{ lst | join(',') }})).should eq("a,b")
    sub.substitute(%({{ pkg | default('x') }})).should eq("nginx")
  end

  it "Crinja's own lenient render maps an unknown filter to the same hard failure instead of returning the raw template text" do
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(vars)
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'totally_bogus_filter_xyz'.") do
      renderer.render(%({{ 5 | totally_bogus_filter_xyz }}))
    end
  end

  it "Crinja's lenient render still returns the original text for other failures (lenient undefined is deliberate)" do
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(vars)
    renderer.render(%({% if never_set_var == 'x' %}yes{% else %}no{% endif %})).should eq("no")
  end

  it "when: pre-pass accepts an implemented community.general FQCN spelling" do
    # Previously the compile-time scanner read only up to the first dot,
    # so this hard-failed as "No filter named 'community'." even though
    # the same chain inside a task param dispatched fine.
    v = Hash(String, JSON::Any).new
    v["left"] = JSON.parse(%({"a": 1}))
    v["right"] = JSON.parse(%({"b": 2}))
    Krikri::ConditionalEvaluator.evaluate(
      %(false and left | community.general.lists_mergeby(right)), v).should be_false
  end

  it "when: pre-pass raises for an unknown collection-qualified filter, naming the full FQCN" do
    expect_raises(Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'nephelaiio.plugins.sorted_get'.") do
      Krikri::ConditionalEvaluator.evaluate(
        %(false and pkg | nephelaiio.plugins.sorted_get(ovr)), vars)
    end
  end
end
