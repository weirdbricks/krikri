require "crinja"

# Real Jinja2's `and`/`or` are short-circuit VALUE operators, same as
# Python: `x or y` evaluates to `x` if `x` is truthy, else to `y` -
# whichever operand actually decided the outcome, not a boolean. Crinja's
# own `Operator::And`/`Operator::Or` (lib/crinja/src/lib/operator/
# logic.cr) both collapse straight to `Value.new !!(...)`, discarding the
# real operand entirely - `{{ '' or 'fallback' }}` renders the literal
# text `"True"` instead of `"fallback"`. `crinja_truthy_ext.cr`'s own doc
# comment already flagged this exact `op.truthy?`-collapses-the-value
# behavior as the root cause of a related bug it fixed (empty-string
# `and`/`or` operands read as falsy) without going on to fix the
# discarded-value issue itself - this is that follow-up fix.
#
# This is an INDEPENDENT copy of the same bug class round 19
# (0.9.289-0.9.290) found and fixed in this codebase's own hand-rolled
# evaluator - Crinja has its own separate implementation, so needed its
# own separate fix. `x or 'default'` is the single most common
# Ansible-authored Jinja2 defaulting idiom, so this is a
# higher-than-usual-impact fix for a one-file, two-method patch. Found
# via the differential test harness (scripts/crinja_corpus/, see
# CRINJA.md).
class Crinja::Operator::And
  def value(env : Crinja, op1 : Value, &op2 : -> Value) : Value
    op1.truthy? ? op2.call : op1
  end
end

class Crinja::Operator::Or
  def value(env : Crinja, op1 : Value, &op2 : -> Value) : Value
    op1.truthy? ? op1 : op2.call
  end
end
