require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/krikri_jinja_filters"

# `X is defined` where X is a CALL (`lookup('vars', name) is defined`) is
# not a variable-name existence check - the gsub-the-suffix-and-look-up-
# the-name handling answered False for every existing variable, so
# sscheib.openwrt_extroot's assert loop failed its
# `lookup('ansible.builtin.vars', '_ext_quiet_assert') is defined` check
# at the very first task (round 5250000). A call-shaped operand now falls
# through to the bare-call delegation, whose engine render answers the
# test on the call's real result. Verified against ansible-core 2.19.11
# (existing name -> True, missing name -> False/skip) before being
# encoded here.
describe "is defined on a call operand (conditional_is_defined_call_test.cr)" do
  private def vars
    {"present" => JSON::Any.new(true)}
  end

  it "answers is defined on an existing variable through a lookup call" do
    Krikri::ConditionalEvaluator.evaluate("lookup('vars', 'present') is defined", vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("lookup('ansible.builtin.vars', 'present') is defined", vars).must_equal(true)
  end

  it "answers is defined False for a missing variable through a lookup call" do
    Krikri::ConditionalEvaluator.evaluate("lookup('vars', 'absent_var') is defined", vars).must_equal(false)
  end

  it "keeps the name-existence spelling unchanged" do
    Krikri::ConditionalEvaluator.evaluate("present is defined", vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("absent_var is defined", vars).must_equal(false)
  end
end
