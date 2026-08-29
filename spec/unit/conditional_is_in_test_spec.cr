require "../spec_helper"
require "../../src/crystal_play/conditional_evaluator"

# Jinja2's `in` TEST spelling (`x is in y` / `x is not in y`, Jinja
# 2.10+). Found live benchmarking devsec.hardening.os_hardening during
# the OPUS_PERFORMANCE_IMPROVEMENTS item-1 round: its user_accounts.yml
# gates every interactive-user task on `item is not in
# os_always_ignore_users`, and the ConditionalEvaluator's `not in`
# OPERATOR handler ran first and split on " not in ", handing the
# containment check a left operand of "item is" - which failed every
# looped item with "Error while evaluating conditional: 'item is' is
# undefined" instead of skipping/running it. Behavior below verified
# against real ansible-core 2.19.4 before being encoded here.
describe CrystalPlay::ConditionalEvaluator do
  vars = {
    "item"   => JSON::Any.new("root"),
    "other"  => JSON::Any.new("alice"),
    "ignore" => JSON.parse(%(["root", "daemon"])),
  }

  it "treats `is in` as the containment operator" do
    CrystalPlay::ConditionalEvaluator.evaluate("item is in ignore", vars).should be_true
    CrystalPlay::ConditionalEvaluator.evaluate("other is in ignore", vars).should be_false
  end

  it "treats `is not in` as the negated containment operator" do
    CrystalPlay::ConditionalEvaluator.evaluate("item is not in ignore", vars).should be_false
    CrystalPlay::ConditionalEvaluator.evaluate("other is not in ignore", vars).should be_true
  end

  it "still handles the bare operator spellings unchanged" do
    CrystalPlay::ConditionalEvaluator.evaluate("item in ignore", vars).should be_true
    CrystalPlay::ConditionalEvaluator.evaluate("other not in ignore", vars).should be_true
  end

  it "does not disturb an unrelated `is not <test>` condition" do
    # The normalization keys on the literal " is not in " / " is in ",
    # so `is not defined` and friends must be untouched by it.
    CrystalPlay::ConditionalEvaluator.evaluate("missing is not defined", vars).should be_true
    CrystalPlay::ConditionalEvaluator.evaluate("item is defined", vars).should be_true
  end
end
