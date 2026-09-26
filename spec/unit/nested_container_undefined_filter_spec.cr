require "../spec_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# Real bug found in the mismatch-traefik round: a `vars:` entry whose
# nested dict value is itself unrendered Jinja referencing a name set
# nowhere (`my_config: {foo: {bar: "{{ some_undefined_var }}"}}`) fed
# through a serializing filter (`{{ my_config | to_json }}`, and the
# same via `| to_nice_yaml`) silently serialized the literal text
# "undefined" as ordinary content - real ansible-playbook fails
# immediately ("'some_undefined_var' is undefined", because it
# templates every nested string value at every level, strictly).
#
# Both of this codebase's independent evaluators were reachable (see
# CLAUDE.md): the hand-rolled FilterEngine path via
# ExpressionEvaluator's filter-chain head re-render, and the vendored
# Crinja path via JinjaRenderer's own context conversion - both
# converge on rerender_nested_templates/rerender_string_value, which
# used to render nested leaves LENIENTLY. Every expectation below was
# verified against real ansible-core running the equivalent playbook.
describe "an undefined variable nested inside a dict/list value fed through a filter" do
  v_base = Hash(String, JSON::Any).new
  v_base["my_config"] = JSON.parse(%({"foo": {"bar": "{{ some_undefined_var }}"}}))

  it "raises from the hand-rolled FilterEngine path (to_json)" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v_base)
    expect_raises(Krikri::UndefinedVariableError, /'some_undefined_var' is undefined/) do
      evaluator.evaluate("my_config | to_json")
    end
  end

  it "raises through the full substitute pipeline for to_nice_yaml (a Crinja-dispatched filter)" do
    # to_nice_yaml is NOT in FilterEngine::KNOWN_FILTER_NAMES - the chain
    # dispatch first tries Crinja (whose context conversion now raises),
    # falls back to the hand-rolled chain head (whose re-render raises
    # the same way), so the task fails like real Ansible instead of
    # serializing the sentinel text. JinjaRenderer#render's own direct
    # entry point deliberately swallows generic errors (lenient
    # give-back-the-text), so this goes through VarSubstitutor#substitute
    # - the task-arg path a copy: content: actually takes.
    sub = Krikri::VarSubstitutor.new(vars: v_base)
    expect_raises(Krikri::UndefinedVariableError, /'some_undefined_var' is undefined/) do
      sub.substitute(%({{ my_config | to_nice_yaml }}))
    end
  end

  it "raises from rerender_nested_templates itself, naming the innermost missing var" do
    expect_raises(Krikri::UndefinedVariableError, /'some_undefined_var' is undefined/) do
      Krikri::VariableSubstitutor::JinjaRenderer.rerender_nested_templates(
        v_base["my_config"],
        Krikri::VarSubstitutor.new(vars: v_base),
      )
    end
  end

  it "still renders a nested leaf that guards its own missing name with default()" do
    # The leniency real Ansible itself shows - a `default()`-guarded
    # nested leaf is legitimately defined-by-fallback - must survive
    # the strict fix, same carve-out raise_if_strict_undefined applies.
    v = Hash(String, JSON::Any).new
    v["cfg"] = JSON.parse(%({"bar": "{{ missing_name | default('GUARDED') }}"}))
    result = Krikri::VariableSubstitutor::JinjaRenderer.rerender_nested_templates(
      v["cfg"],
      Krikri::VarSubstitutor.new(vars: v),
    )
    result.as_h["bar"].as_s.should eq("GUARDED")
  end

  it "still serializes a nested leaf that resolves to a real value" do
    v = Hash(String, JSON::Any).new
    v["real_value"] = JSON::Any.new("present")
    v["cfg"] = JSON.parse(%({"foo": {"bar": "{{ real_value }}"}}))
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
    renderer.render(%({{ cfg | to_json }})).should eq(%({"foo": {"bar": "present"}}))
  end
end
