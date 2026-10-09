require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_filters"

# A container variable whose own value has leaves that are still unrendered
# Jinja (`accounts: ["{{ myuser }}"]`) must compare by its RENDERED value in
# a `when:`/comparison - Ansible's recursive re-templating renders every
# leaf before the comparison sees it, so `when: accounts != ['root']`
# skips (before this fix, krikri compared the literal template text and
# ran the gated task on every host). Found in round 5250154 against the
# real role l3d.dotfiles, root cause confirmed against real
# ansible-playbook 2.19.11 (real skips, krikri ran the task).
describe "conditional container re-render (conditional_container_rerender_test.cr)" do
  private def vars
    {
      "myuser"   => JSON::Any.new("root"),
      "accounts" => JSON.parse(%(["{{ myuser }}"])),
    }
  end

  it "renders a container's templated leaves before a bare when-list comparison" do
    # Same when-list shape l3d.dotfiles ran with accounts on root:
    # `accounts != ['root']` is False for the rendered list, and the
    # `!= 'root'` clause is True exactly as Ansible evaluates it
    # (['root'] != 'root').
    Krikri::ConditionalEvaluator.evaluate(
      "accounts is defined and accounts != ['root']", vars
    ).must_equal(false)
  end

  it "runs the task when the rendered list genuinely differs" do
    other = {
      "myuser"   => JSON::Any.new("deploy"),
      "accounts" => JSON.parse(%(["{{ myuser }}"])),
    }
    Krikri::ConditionalEvaluator.evaluate("accounts != ['root']", other).must_equal(true)
  end

  it "renders a container's templated leaves nested one level deeper" do
    nested = {
      "myuser" => JSON::Any.new("root"),
      "conf"   => JSON.parse(%({"users": ["{{ myuser }}"]})),
    }
    Krikri::ConditionalEvaluator.evaluate("conf.users == ['root']", nested).must_equal(true)
  end

  it "keeps a container leaf that bottoms out at an undefined name raw (lazy, like round 952484)" do
    # The untouched-undefined-sibling round-952484 semantics in comparison
    # form: an unresolvable leaf is left in its raw form rather than
    # failing a comparison that never needs it, in both the task-level
    # and lenient evaluation paths.
    dangling = {
      "accounts" => JSON.parse(%(["{{ myuser }}"])),
    }
    Krikri::ConditionalEvaluator.evaluate("accounts != ['root']", dangling).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("accounts != ['root']", dangling, raise_undefined: true).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate("accounts == ['root']", dangling).must_equal(false)
  end

  it "renders a container's templated leaves in the {{ }} comparison path" do
    evaluator = Krikri::VariableSubstitutor::ComparisonEvaluator.new(vars)
    # ComparisonEvaluator returns Crystal-style lowercase text.
    evaluator.evaluate("accounts != ['root']").must_equal("false")
  end
end
