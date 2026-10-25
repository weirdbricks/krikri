require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# assert: and when: both evaluate ordering comparisons through
# ConditionalEvaluator. Python refuses a str against a number there, and
# ansible fails the task (issue #219: a role default '10' asserted
# `| default(0) >= 1`), so the conditional must refuse it too.
describe Krikri::ConditionalEvaluator do
  it "raises OrderingTypeError for a numeric string ordered against a number" do
    v = Hash(String, JSON::Any).new
    v["git_op_status_delay"] = JSON::Any.new("10")
    assert_raises_message(Krikri::ConditionalEvaluator::OrderingTypeError, /'>=' not supported between instances of '_AnsibleTaggedStr' and 'int'/) do
      Krikri::ConditionalEvaluator.evaluate("git_op_status_delay >= 1", v, strict: true, raise_undefined: true)
    end
  end

  # ansible tags only the strings it read from yaml files (role defaults,
  # vars, task-arg literals), so a fact-sourced string is reported as
  # plain 'str' in the TypeError (issue #344) - reporting
  # '_AnsibleTaggedStr' there named a type the real ansible never printed.
  it "reports a fact operand's string as plain 'str' (issue #344)" do
    v = Hash(String, JSON::Any).new
    v["ansible_distribution_version"] = JSON::Any.new("7.9")
    assert_raises_message(Krikri::ConditionalEvaluator::OrderingTypeError, /'>=' not supported between instances of 'str' and 'int'/) do
      Krikri::ConditionalEvaluator.evaluate("ansible_distribution_version >= 7", v, strict: true, raise_undefined: true)
    end
  end

  it "reports an ansible_facts subscript operand's string as plain 'str' too" do
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"distribution_version": "7.9"}))
    assert_raises_message(Krikri::ConditionalEvaluator::OrderingTypeError, /'>=' not supported between instances of 'str' and 'int'/) do
      Krikri::ConditionalEvaluator.evaluate("ansible_facts['distribution_version'] >= 7", v, strict: true, raise_undefined: true)
    end
  end

  it "keeps '_AnsibleTaggedStr' for a non-fact variable next to the fact case" do
    v = Hash(String, JSON::Any).new
    v["my_variable"] = JSON::Any.new("7.9")
    assert_raises_message(Krikri::ConditionalEvaluator::OrderingTypeError, /'>=' not supported between instances of '_AnsibleTaggedStr' and 'int'/) do
      Krikri::ConditionalEvaluator.evaluate("my_variable >= 7", v, strict: true, raise_undefined: true)
    end
  end

  it "keeps numeric-to-numeric ordering working" do
    v = Hash(String, JSON::Any).new
    v["count"] = JSON::Any.new(10_i64)
    Krikri::ConditionalEvaluator.evaluate("count >= 1", v, strict: true, raise_undefined: true).must_equal(true)
  end
end
