require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

describe "Krikri::ConditionalEvaluator (conditional_quoted_operator_test.cr)" do
  private def vars
    {
      "mounts"    => JSON.parse(%q([{"mount": "/var/log/audit"}, {"mount": "/home"}])),
      "only_home" => JSON.parse(%q([{"mount": "/home"}])),
      "x"         => JSON.parse(%q("c")),
    }
  end

  # ansible-lockdown.ubuntu24_stig gates a whole block on this shape
  # (round 1794130429, issue #983). The `==` inside selectattr's own
  # argument list is not a top-level comparison; splitting on it left the
  # truncated chain `selectattr('mount', '` and hard-failed the task with
  # "Syntax error in expression: No filter named 'selectattr('mount', ''."
  # (exit code 2) where ansible-core 2.19 compares the filtered list's
  # length against 0 and merely skips. Live-verified both directions
  # against ansible-core 2.19.11.
  it "compares a selectattr-filtered list's length without treating the quoted '==' as a comparison" do
    Krikri::ConditionalEvaluator.evaluate(
      %q(mounts | selectattr('mount', '==', '/var/log/audit') | list | length > 0), vars
    ).must_equal(true)
  end

  it "reads the same selectattr gate as false when nothing matches" do
    Krikri::ConditionalEvaluator.evaluate(
      %q(only_home | selectattr('mount', '==', '/var/log/audit') | list | length > 0), vars
    ).must_equal(false)
  end

  it "handles the equalto spelling of the same gate" do
    Krikri::ConditionalEvaluator.evaluate(
      %q(mounts | selectattr('mount', 'equalto', '/var/log/audit') | list | length > 0), vars
    ).must_equal(true)
  end

  it "splits a comparison at the first real operator, not a quoted one" do
    Krikri::ConditionalEvaluator.evaluate(%q(x != "a==b"), vars).must_equal(true)
  end
end
