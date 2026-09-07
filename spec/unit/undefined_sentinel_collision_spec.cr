require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# The dotted-index "undefined"-string collision (KNOWN_MISSING.md open gap):
# ExpressionEvaluator represents "this reference has no value" as the plain
# string "undefined", and the strict-undefined re-check for chained
# dotted/bracket expressions decides by comparing its own rendered output
# against that same literal text. When the real value at that index genuinely
# IS the text "undefined" (verified live: `command: printf 'undefined'` +
# `register: s2`), the check can't tell a real value from an actual miss.
# Real ansible-core 2.19 renders `{{ s2.stdout_lines.0 }}` fine in that case;
# this engine raised "'s2.stdout_lines.0' is undefined" on the dotted form
# while the bracket form `s2.stdout_lines[0]` (resolved structurally, no
# string re-check) was already correct.
private def sub(vars)
  Krikri::VarSubstitutor.new(vars: vars, host_name: "h1")
end

describe "dotted-index 'undefined'-string sentinel collision" do
  it "renders a real 'undefined' string value on a dotted numeric index under strict" do
    vars = {"s2" => JSON.parse(%({"stdout_lines": ["undefined"]}))}
    sub(vars).substitute("{{ s2.stdout_lines.0 }}", strict: true).should eq("undefined")
  end

  it "renders the same value on the bracket form under strict (already correct)" do
    vars = {"s2" => JSON.parse(%({"stdout_lines": ["undefined"]}))}
    sub(vars).substitute("{{ s2.stdout_lines[0] }}", strict: true).should eq("undefined")
  end

  it "renders the real value non-strict on a dotted numeric index" do
    vars = {"s2" => JSON.parse(%({"stdout_lines": ["undefined"]}))}
    sub(vars).substitute("{{ s2.stdout_lines.0 }}").should eq("undefined")
  end

  it "still raises for a genuinely undefined dotted numeric index under strict" do
    vars = {"s2" => JSON.parse(%({"stdout_lines": ["real"]}))}
    expect_raises(Krikri::UndefinedVariableError, /'s2\.stdout_lines\.1' is undefined/) do
      sub(vars).substitute("{{ s2.stdout_lines.1 }}", strict: true)
    end
  end

  it "still raises for a genuinely undefined dotted root under strict" do
    expect_raises(Krikri::UndefinedVariableError, /'nope\.0' is undefined/) do
      sub(Hash(String, JSON::Any).new).substitute("{{ nope.0 }}", strict: true)
    end
  end
end
