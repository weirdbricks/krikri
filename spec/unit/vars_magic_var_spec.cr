require "../spec_helper"
require "../../src/krikri/conditional_evaluator"

# Real Ansible's `vars` magic variable - a dict of every variable in
# scope. Most real uses are membership tests rather than value reads:
# `prometheus.prometheus`'s own preflight does
#
#   __common_parent_role_short_name ~ '_skip_install' not in vars
#
# which crystal failed with "'vars' is undefined", stopping that role at
# task 6 while real ansible-playbook completed all 33 (round 198). That
# blocked the whole prometheus.prometheus collection.
#
# The Crinja path already synthesised a `vars` dict; the hand-rolled
# ConditionalEvaluator - which is what `when:`/`assert:` go through -
# did not. TaskExecutor#build_vars_context now puts a real `vars` key in
# the context so both evaluators see the same thing.
describe "vars magic variable" do
  vars = {
    "my_thing" => JSON::Any.new("present"),
    "prefix"   => JSON::Any.new("my"),
  }

  # `vars` as the executor now builds it: a snapshot of the context that
  # deliberately excludes itself.
  context_with_vars = begin
    snapshot = Hash(String, JSON::Any).new
    vars.each { |k, v| snapshot[k] = v }
    vars.merge({"vars" => JSON::Any.new(snapshot)})
  end

  it "answers membership for a variable that exists" do
    Krikri::ConditionalEvaluator.evaluate("'my_thing' in vars", context_with_vars).should be_true
  end

  it "answers membership for one that does not" do
    Krikri::ConditionalEvaluator.evaluate("'definitely_absent' in vars", context_with_vars).should be_false
    Krikri::ConditionalEvaluator.evaluate("'definitely_absent' not in vars", context_with_vars).should be_true
  end

  it "handles the concatenated form the prometheus collection uses" do
    # `prefix ~ '_thing'` builds the name at runtime - this is the exact
    # shape that surfaced the bug.
    Krikri::ConditionalEvaluator.evaluate("prefix ~ '_thing' in vars", context_with_vars).should be_true
    Krikri::ConditionalEvaluator.evaluate("prefix ~ '_absent' not in vars", context_with_vars).should be_true
  end

  it "does not let the snapshot contain itself" do
    # Verified against real ansible-core 2.19.4, where `'vars' in vars`
    # is False. A self-containing snapshot would also nest one copy per
    # task, since the context is layered on cached base contexts.
    context_with_vars["vars"].as_h.has_key?("vars").should be_false
  end
end
