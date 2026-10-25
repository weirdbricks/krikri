require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# Issue #338: real ansible renders `{{ python3-pkgs }}` (an unspaced minus
# between two identifiers) as Jinja subtraction `python3 - pkgs` and its
# strict templar fails the task with "'python3' is undefined" - meanwhile
# (pre-fix) this engine's spaces-only " - " rule never recognised the
# operator, so the unknown-variable sentinel flowed onward as the literal
# text "undefined" both into a debug msg and, worse, as an apt package
# name. Ansible observed live against ansible-core 2.19.11.
describe "unspaced-minus binary subtraction (issue #338)" do
  include RaisesAssertion

  it "strict task-param render of {{ python3-pkgs }} fails the way ansible does" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new)
    assert_raises_message(Krikri::UndefinedVariableError, /'python3' is undefined/) do
      sub.substitute("{{ python3-pkgs }}", strict: true)
    end
  end

  it "raises the strict-undefined message for an unresolvable left operand of an unspaced minus" do
    v = Hash(String, JSON::Any).new
    v["port"] = JSON::Any.new(8080_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::PlusMinusOperandError, "'python3' is undefined") do
      evaluator.evaluate("python3-pkgs")
    end
    # Same strictness the spaced operator already had - only the split
    # recognition changed, not the operand handling.
    assert_raises_message(Krikri::PlusMinusOperandError, "'missing_var' is undefined") do
      evaluator.evaluate("port - missing_var")
    end
  end

  it "subtracts unspaced exactly like the spaced form (a-1 with a=5 is 4)" do
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new(5_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("a-1").must_equal("4")
    evaluator.evaluate("a - 1").must_equal("4")
  end

  it "strict task-param render of {{ a-1 }} with a=5 resolves to 4" do
    sub = Krikri::VarSubstitutor.new(vars: {"a" => JSON::Any.new(5_i64)} of String => JSON::Any)
    sub.substitute("{{ a-1 }}", strict: true).must_equal("4")
  end

  it "identifiers genuinely ending in e still subtract (lexer would too)" do
    v = Hash(String, JSON::Any).new
    v["x5e"] = JSON::Any.new(100_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("x5e-2").must_equal("98")
  end

  it "keeps a quoted string carrying a dash literal (the depth tracker's own territory)" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'a-b'").must_equal("a-b")
  end

  it "keeps the float exponent form 1e-5 numeric, never a split" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("1e-5").must_equal("1e-05")
    evaluator.evaluate("1E-5").must_equal("1e-05")
  end

  it "unspaced minus against a paren operand still subtracts (a-(-1) is 6)" do
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new(5_i64)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("a-(-1)").must_equal("6")
    evaluator.evaluate("a-(a)").must_equal("0")
  end
end
