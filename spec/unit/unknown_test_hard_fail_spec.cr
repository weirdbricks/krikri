require "../spec_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/conditional_evaluator"

# An unknown `is <test>` TEST name must hard-fail with real Jinja2/
# ansible-core's own wording ("No test named 'X'.", a compile-time
# TemplateAssertionError - the test set is validated before any call is
# attempted), never silently evaluate as if it were a real test. There
# is a `list` FILTER and an `is iterable` test, but NO `is list` TEST.
# Found via sunfoxcz.dkim (round 74502): its first `fail:` task's when:
# list is [dkim_domains is not defined, dkim_domains is not list]; real
# Ansible fails immediately with "Syntax error in expression: No test
# named 'list'.", while here the first clause was already False, the
# short-circuit never reached the invalid clause, and the role ran 6
# tasks deep before failing elsewhere. Previously the error, when it
# WAS reached, was also mislabeled - Crinja's unknown-TEST error was
# mapped onto the filter wording as "No filter named 'unknown'."
describe "unknown test names hard-fail like real Jinja2/Ansible" do
  vars = {
    "lst"          => JSON.parse(%(["a", "b"])),
    "dkim_domains" => JSON.parse(%(["example.com"])),
  } of String => JSON::Any
  sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "h")

  it "raises for `x is list` in a conditional, with real Ansible's exact wording" do
    expect_raises(Krikri::VariableSubstitutor::UnknownTestError,
      "No test named 'list'.") do
      Krikri::ConditionalEvaluator.evaluate(%(lst is list), vars)
    end
  end

  it "raises for `is not list` in a conditional" do
    expect_raises(Krikri::VariableSubstitutor::UnknownTestError,
      "No test named 'list'.") do
      Krikri::ConditionalEvaluator.evaluate(%(lst is not list), vars)
    end
  end

  it "raises at COMPILE time even when and/short-circuiting never reaches the invalid clause" do
    # The exact sunfoxcz.dkim shape: the first clause is already False,
    # but real Jinja resolves every test name in the whole expression
    # when it compiles the template - the task must fail, not skip.
    expect_raises(Krikri::VariableSubstitutor::UnknownTestError,
      "No test named 'list'.") do
      Krikri::ConditionalEvaluator.evaluate(
        %(dkim_domains is not defined and dkim_domains is not list), vars)
    end
  end

  it "raises for an unknown test through the lenient Crinja render path too" do
    # Previously mislabeled "No filter named 'unknown'." - Crinja's
    # unknown-TEST error wording wasn't recognized, so it fell into the
    # generic unknown-filter mapping with a discarded name.
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(vars)
    expect_raises(Krikri::VariableSubstitutor::UnknownTestError,
      "No test named 'list'.") do
      renderer.render(%({% if lst is list %}yes{% endif %}))
    end
  end

  it "still accepts implemented `is` tests through the same paths" do
    Krikri::ConditionalEvaluator.evaluate(%(lst is iterable), vars).should be_true
    Krikri::ConditionalEvaluator.evaluate(%(lst is not string), vars).should be_true
    Krikri::ConditionalEvaluator.evaluate(%(lst is sequence), vars).should be_true
    sub.substitute(%({% if lst is iterable %}yes{% else %}no{% endif %})).should eq("yes")
  end
end
