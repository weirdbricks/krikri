require "../spec_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/jinja_filters"
require "../../src/krikri/variable_substitutor/crinja_renderer"

# P2.4-P2.7 (FINDINGS_CHECKLIST.md / PATTERN2_AUDIT.md): the remaining
# core test spellings.
#
# - `true`/`false` are BOOLEAN IDENTITY tests (only real True/False
#   pass - NOT truthiness: "yes", 1, [] must all fail them).
# - `falsy` is !truthy (null, false, 0, "", empty list/dict).
# - `uri`/`url` URL-shape tests; `abs`-as-test; `isnan`/`nan`.
# - `filter`/`test` meta-tests: registry lookups (Crinja path only -
#   documented parity difference: the hand-rolled evaluator has no
#   filter-registry notion, and P2.7 is explicitly low priority).
#
# JSON::Any vars work with pure Crinja only after its JSON shim is
# loaded (defines Crinja.value(JSON::Any) + Crinja::Object support).
require "crinja/json"

# Parity contract: every value-level test is exercised through BOTH the
# hand-rolled ConditionalEvaluator AND a pure Crinja render.
# Pure Crinja renders take native Crystal containers, not JSON::Any -
# convert the fixture vars so the same data feeds both engines.
private def crinja_render(tpl : String, vars : NamedTuple | Hash(String, JSON::Any) | Nil = nil) : String
  env = Crinja.new
  env.from_string(tpl).render(vars)
end

describe "boolean-identity / URL / NaN / meta tests (P2.4-P2.7)" do
  vars = {
    "yes_str"    => JSON::Any.new("yes"),
    "flag_true"  => JSON::Any.new(true),
    "flag_false" => JSON::Any.new(false),
    "num_zero"   => JSON::Any.new(0_i64),
    "num_one"    => JSON::Any.new(1_i64),
    "empty_str"  => JSON::Any.new(""),
    "empty_list" => JSON.parse(%([])),
    "url_str"    => JSON::Any.new("https://example.com/a?b=1"),
    "not_url"    => JSON::Any.new("example.com/a"),
    "float_nan"  => JSON::Any.new(Float64::NAN),
    "float_num"  => JSON::Any.new(3.5),
  }

  describe "true / false boolean-identity tests (P2.4)" do
    it "passes only for the actual booleans (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("flag_true is true", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("flag_false is true", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("flag_true is false", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("flag_false is false", vars).should be_true
    end

    it "rejects truthy/falsy NON-booleans (identity, not truthiness)" do
      # These are the cases a truthiness implementation gets wrong.
      Krikri::ConditionalEvaluator.evaluate("yes_str is true", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("num_one is true", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("num_zero is false", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("empty_list is false", vars).should be_false
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("flag_false is not true", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("flag_true is not false", vars).should be_true
    end
  end

  describe "falsy test (P2.4)" do
    it "is !truthy: null/false/0/empty-string/empty-list pass (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("flag_false is falsy", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("num_zero is falsy", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("empty_str is falsy", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("empty_list is falsy", vars).should be_true
    end

    it "rejects truthy values (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("yes_str is falsy", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("num_one is falsy", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("flag_true is falsy", vars).should be_false
    end
  end

  describe "uri / url tests (P2.5)" do
    it "accepts scheme://rest strings (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("url_str is uri", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("url_str is url", vars).should be_true
    end

    it "rejects scheme-less strings (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("not_url is uri", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("not_url is url", vars).should be_false
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("not_url is not uri", vars).should be_true
    end
  end

  describe "abs / isnan / nan tests (P2.6)" do
    it "abs passes for numbers only (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("num_one is abs", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("float_num is abs", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("yes_str is abs", vars).should be_false
    end

    it "isnan/nan pass only for a real NaN float (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("float_nan is isnan", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("float_nan is nan", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("float_num is isnan", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("num_one is nan", vars).should be_false
    end
  end

  # ---- Cross-engine parity: pure Crinja render ----
  describe "parity with pure Crinja render" do
    it "true/false agree with the hand-rolled evaluator (identity semantics)" do
      crinja_render("{{ flag_true is true }}", vars).should eq("True")
      crinja_render("{{ yes_str is true }}", vars).should eq("False")
      crinja_render("{{ flag_false is false }}", vars).should eq("True")
      crinja_render("{{ num_zero is false }}", vars).should eq("False")
    end

    it "falsy agrees with the hand-rolled evaluator" do
      crinja_render("{{ empty_list is falsy }}", vars).should eq("True")
      crinja_render("{{ num_one is falsy }}", vars).should eq("False")
    end

    it "uri/url agree with the hand-rolled evaluator" do
      crinja_render("{{ url_str is uri }}", vars).should eq("True")
      crinja_render("{{ not_url is url }}", vars).should eq("False")
    end

    it "abs/isnan agree with the hand-rolled evaluator" do
      crinja_render("{{ num_one is abs }}", vars).should eq("True")
      crinja_render("{{ float_nan is isnan }}", vars).should eq("True")
      crinja_render("{{ float_num is isnan }}", vars).should eq("False")
    end

    it "filter/test meta-tests resolve against the combined registry" do
      # 'upper' is a Crinja built-in; 'ternary' is krikri-playbook's own
      # registration - both must be visible.
      crinja_render("{{ x is filter('upper') }}").should eq("True")
      crinja_render("{{ x is filter('ternary') }}").should eq("True")
      crinja_render("{{ x is filter('no_such_filter') }}").should eq("False")
      crinja_render("{{ x is test('defined') }}").should eq("True")
      crinja_render("{{ x is test('version') }}").should eq("True")
      crinja_render("{{ x is test('no_such_test') }}").should eq("False")
    end
  end

  # ---- Real-role regression ----
  it "works inside a real {% if %} conditional through CrinjaRenderer" do
    v = Hash(String, JSON::Any).new
    v["docker_enable"] = JSON::Any.new(true)
    v["registry_url"] = JSON::Any.new("https://registry.example.com")
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(v)
    # Boolean-identity gate shape roles actually write.
    renderer.render(%({% if docker_enable is true %}enabled{% else %}disabled{% endif %})).should eq("enabled")
    # URL validation of a user-supplied endpoint var.
    renderer.render(%({% if registry_url is url %}ok{% else %}bad{% endif %})).should eq("ok")
  end
end
