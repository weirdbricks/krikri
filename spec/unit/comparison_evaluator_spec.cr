require "../spec_helper"
require "../../src/krikri/variable_substitutor/comparison_evaluator"

private def vars(hash : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  hash.each { |k, v| result[k] = JSON::Any.new(v) }
  result
end

describe Krikri::VariableSubstitutor::ComparisonEvaluator do
  it "evaluates == against a variable and a literal" do
    v = vars({"rc" => 0_i64} of String => JSON::Any::Type)
    evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("rc == 0").should eq("true")
  end

  it "evaluates numeric < across variables" do
    v = vars({"count" => 3_i64} of String => JSON::Any::Type)
    evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("count < 5").should eq("true")
  end

  it "evaluates nested variable access (result.rc)" do
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"rc": 1}))
    evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("result.rc == 1").should eq("true")
  end

  it "returns false when neither side is a recognized operator" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
    evaluator.evaluate("no operator here").should eq("false")
  end

  describe "filter chains as comparison operands" do
    # Real, previously-shipped bug: a comparison operator was detected
    # before any `|` filter check, so `{{ mylist | length > 0 }}` (used
    # directly in a template, not just when:) always evaluated "false" -
    # the filter-chain text on the left was treated as a literal
    # (undefined) variable name instead of being resolved and filtered.

    it "evaluates a filter chain on the left side of a comparison" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate("mylist | length > 0").should eq("true")
    end

    it "evaluates false when the filtered value doesn't satisfy the comparison" do
      v = Hash(String, JSON::Any).new
      v["mylist"] = JSON::Any.new([] of JSON::Any)
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate("mylist | length > 0").should eq("false")
    end

    it "evaluates a filter chain on a dotted (nested) operand" do
      v = Hash(String, JSON::Any).new
      v["result"] = JSON.parse(%({"stdout": "  hello  "}))
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate(%(result.stdout | trim == "hello")).should eq("true")
    end

    it "evaluates a `~`-concatenated operand on the right side of a comparison" do
      # Real bug found benchmarking ansible-community.ansible-vault's own
      # `installed_vault_version.stdout != vault_version~('+ent' if
      # vault_enterprise)` - the right operand has no `|` and doesn't
      # start with `(`, so it fell through to a plain (always-undefined)
      # variable lookup on the whole literal "vault_version~(...)" text,
      # never equal to anything.
      v = Hash(String, JSON::Any).new
      v["installed"] = JSON::Any.new("2.0.3")
      v["vault_version"] = JSON::Any.new("2.0.3")
      v["vault_enterprise"] = JSON::Any.new(false)
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate("installed != vault_version~('+ent' if vault_enterprise)").should eq("false")
    end

    it "re-templates a bare comparison operand when its raw value is still unrendered Jinja" do
      # Real bug found alongside the `~` one above, on the exact same
      # role: `installed_vault_version.stdout != vault_version` alone
      # (no `~` at all) ALSO always evaluated true, because
      # vault_version's own raw value was itself unrendered Jinja (`{{
      # lookup('env', 'VAULT_VERSION') | default('2.0.3', true) }}`) -
      # lookup_simple_variable's plain-lookup fallback for a bare
      # comparison operand (no `|`, no `(`, no `~`, no `.`) returned
      # that raw template text unchanged rather than rendering it, so it
      # never matched the real (rendered) value on the other side. `{{
      # vault_version }}` alone rendered correctly elsewhere (a
      # different code path), masking this for a long time.
      v = Hash(String, JSON::Any).new
      v["installed"] = JSON.parse(%({"stdout": "2.0.3"}))
      v["vault_version"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_CMP_ENV_TEST') | default('2.0.3', true) }}))
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate("installed.stdout != vault_version").should eq("false")
    end

    it "audit pass: re-templates a DOTTED comparison operand's own unrendered value" do
      # Proactive audit (2026-08-11): lookup_simple_variable (the BARE-
      # identifier case, fixed above) had this guard; lookup_nested_
      # variable and resolve_json (the DOTTED-path counterparts, used
      # for `outer.inner == ...` and dotted filter-chain heads) didn't -
      # found by grepping every remaining plain-lookup fallback in the
      # engine after rounds 2-3 turned up 5 independent copies of this
      # bug class.
      v = Hash(String, JSON::Any).new
      v["outer"] = JSON.parse(%({"inner": "{{ real_val }}"}))
      v["real_val"] = JSON::Any.new("resolved")
      evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(v)
      evaluator.evaluate("outer.inner == 'resolved'").should eq("true")
    end
  end
end
