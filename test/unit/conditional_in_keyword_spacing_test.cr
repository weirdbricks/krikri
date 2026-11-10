require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# A whitespace-free `in`/`not in` operator (`'present'in item.state`).
# Real Python/Jinja lexing treats `in` as a keyword wherever it stands,
# so no surrounding whitespace is required, but the hand-rolled
# evaluator only routed the operator on the literal " in "/" not in "
# paddings - caduri.ohmyzsh issue #1100's
# `when: "item.state is not defined or 'present'in item.state"` fell
# through to the bare-variable fallback and failed the task as
# "''present'in item.state' is undefined" (exit 2 in check mode) where
# ansible-core 2.19.11 ran the task (exit 0).
describe "Krikri::ConditionalEvaluator (conditional_in_keyword_spacing_test.cr)" do
  private def vars
    {
      "item"   => JSON.parse(%({"state": "present", "user": "root"})),
      "absent" => JSON.parse(%({"state": "absent"})),
      "domain" => JSON::Any.new("example.com"),
      "label"  => JSON::Any.new("skill in trait"),
      "ignore" => JSON.parse(%(["a", "b"])),
    }
  end

  it "evaluates the issue #1100 unspaced membership clause as true" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'present'in item.state}, vars
    ).must_equal(true)
  end

  it "evaluates the full issue #1100 when: for every loop item" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{item.state is not defined or 'present'in item.state}, vars
    ).must_equal(true)
  end

  it "answers false for an unspaced membership that really misses" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'present'in absent.state}, vars
    ).must_equal(false)
  end

  it "evaluates an unspaced in against a quoted container literal" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'a'in ['a', 'b']}, vars
    ).must_equal(true)
  end

  it "evaluates an unspaced not in against a quoted container literal" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'c'not in ['a', 'b']}, vars
    ).must_equal(true)
  end

  it "keeps the spaced in and not in spellings working" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'a' in ignore and 'c' not in ignore}, vars
    ).must_equal(true)
  end

  it "keeps the is in / is not in test spellings working" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{'a' is in ignore and 'c' is not in ignore}, vars
    ).must_equal(true)
  end

  it "never inserts spaces inside an identifier containing in" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{domain == 'example.com' and domain != 'other'}, vars
    ).must_equal(true)
  end

  it "leaves a quoted in literal untouched" do
    Krikri::ConditionalEvaluator.evaluate(
      %q{label == "skill in trait"}, vars
    ).must_equal(true)
  end
end
