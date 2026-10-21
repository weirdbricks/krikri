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

  it "keeps numeric-to-numeric ordering working" do
    v = Hash(String, JSON::Any).new
    v["count"] = JSON::Any.new(10_i64)
    Krikri::ConditionalEvaluator.evaluate("count >= 1", v, strict: true, raise_undefined: true).must_equal(true)
  end
end
