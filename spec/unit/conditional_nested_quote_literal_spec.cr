require "../spec_helper"
require "../../src/krikri/conditional_evaluator"

# A condition that is entirely ONE quoted string literal is a Jinja
# constant (truthy iff its interior is non-empty), even when the interior
# itself uses the other quote character. Found live in round 902000 via
# konstruktoid.hardening's resolvedconf.yml:
#
#   failed_when:
#     - apt_resolved is failed
#     - not "'No package matching' in apt_resolved.msg"
#
# The second clause is a DOUBLE-quoted string literal whose content
# happens to contain single quotes - in real Jinja2 `not "<string>"` is
# `not <truthy>` = False, so this failed_when NEVER fires and the play
# continues past a genuinely failed apt task. Verified live against
# ansible-core 2.19.11: BOTH the matching and non-matching msg variants
# finish ok=2 failed=0, while the unquoted control spelling
# `not ('No package matching' in apt_resolved.msg)` fails the task
# (failed_when_result: true) when the substring is absent - proving the
# quotes are semantic, not decoration. The old narrow constant check
# (interior must contain no quote character at all) let this literal fall
# through to expression parsing, where the quote-aware ` in ` splitter
# correctly refused to split inside the quotes, #evaluate_in returned
# false, and the enclosing `not` flipped that to True - hard-failing a
# task real Ansible treats as ok (krikri ok=14 failed=1 vs real
# ok=283 failed=0 on the same host).
describe Krikri::ConditionalEvaluator do
  result_vars = JSON.parse(%({"failed": true, "changed": false, "msg": "No package matching 'systemd-resolved' is available"}))
  other_vars = JSON.parse(%({"failed": true, "changed": false, "msg": "Some other error entirely"}))

  vars = {
    "apt_resolved" => result_vars,
    "apt_other"    => other_vars,
  }

  it "treats a double-quoted literal containing single quotes as a truthy constant" do
    # The exact clause shape from konstruktoid.hardening.
    Krikri::ConditionalEvaluator.evaluate(
      %q(not "'No package matching' in apt_resolved.msg"), vars
    ).should be_false
  end

  it "keeps the string-literal reading even when the substring is absent from msg" do
    # Real ansible-core 2.19.11 marks this ok too - the clause never
    # becomes a containment test, so msg content is irrelevant.
    Krikri::ConditionalEvaluator.evaluate(
      %q(not "'No package matching' in apt_other.msg"), vars
    ).should be_false
  end

  it "reads the full joined failed_when list as false when the module failed" do
    # The exact string shape condition_to_string produces for the role's
    # two-clause failed_when list.
    condition = %q((apt_resolved is failed) and (not "'No package matching' in apt_resolved.msg"))
    Krikri::ConditionalEvaluator.evaluate(condition, vars).should be_false
  end

  it "still evaluates the UNQUOTED containment spelling as a real in-test" do
    # Control case, verified live against ansible-core 2.19.11: the
    # unquoted spelling DOES fail the task when the substring is absent
    # (failed_when_result: true) and forgives it when present.
    quoted = %q(not ('No package matching' in apt_resolved.msg))
    unquoted = %q(not ('No package matching' in apt_other.msg))
    Krikri::ConditionalEvaluator.evaluate(quoted, vars).should be_false
    Krikri::ConditionalEvaluator.evaluate(unquoted, vars).should be_true
  end

  it "treats a single-quoted literal containing double quotes as a constant too" do
    Krikri::ConditionalEvaluator.evaluate(%q(not '"quoted text"'), vars).should be_false
  end

  it "keeps truthiness of a bare all-quoted constant unchanged" do
    Krikri::ConditionalEvaluator.evaluate(%q("non-empty literal"), vars).should be_true
    Krikri::ConditionalEvaluator.evaluate(%q('mariadb_version_check.rc == 0'), vars).should be_true
  end

  it "keeps compound conditions that merely start and end with quotes as expressions" do
    # First closing quote is mid-string, so these are NOT single
    # literals and must still parse as comparisons/tests.
    Krikri::ConditionalEvaluator.evaluate(%q('a' == 'a'), vars).should be_true
    Krikri::ConditionalEvaluator.evaluate(%q('a' == 'b'), vars).should be_false
    Krikri::ConditionalEvaluator.evaluate(%q('root' in ignore), {"ignore" => JSON.parse(%(["root"]))}).should be_true
  end

  it "still honors an escaped closing quote inside a literal" do
    Krikri::ConditionalEvaluator.evaluate(%q("a \" b"), vars).should be_true
  end

  it "reads an empty literal as falsy" do
    Krikri::ConditionalEvaluator.evaluate(%q(not ""), vars).should be_true
    Krikri::ConditionalEvaluator.evaluate(%q(not ''), vars).should be_true
  end
end
