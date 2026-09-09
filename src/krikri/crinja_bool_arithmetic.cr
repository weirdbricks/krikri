require "crinja"

# Python's `bool` is an `int` subclass (`True == 1`, `False == 0`), so
# every real-Jinja2/Python arithmetic operator accepts a Bool operand
# and treats it as 0/1: `True + False + False` is `1`, `True * 2` is
# `2`, `sum-of-bools <= 1` is a working mutual-exclusion guard. Crinja's
# `Value#number?` checks `@raw.is_a?(Number)` - and Crystal's `Bool` is
# NOT a `Number` - so every Crinja-side arithmetic operator fell through
# to its non-numeric branch instead: `+` silently STRING-CONCATENATED
# the Python-repr texts ("TrueFalseFalse"), `-`/`*` raised
# "Both operators need to be numeric". The {{ }}-span comparison path
# (ExpressionEvaluator's Crinja-first leading-paren delegation) inherits
# that wrong answer without ever falling back, since Crinja doesn't
# raise on the `+`-of-bools shape.
#
# Found via galaxyproject.galaxy's very first task, `assert: that:
# "(galaxy_manage_clone + galaxy_manage_download + galaxy_manage_
# existing) <= 1"` with three boolean role defaults - real Ansible sums
# them to 1 and the assert passes; krikri failed it before any real work
# ran. Fixed at the VALUE level (not per-operator) so plus/minus/multiply/
# divide/comparator all see the same Python semantics, exactly as they
# do in Python itself - `True == 1` compares equal through the same
# `as_number` path, which is also real-Python-correct.
#
# Scoped to `number?`/`as_number` only: non-arithmetic Bool handling
# (truthiness, `and`/`or`/`not`, `is` tests other than `number`) never
# consults either method, so `{{ true }}` still renders "True" and a
# bare Bool still tests truthy exactly as before.
struct Crinja::Value
  # Python's bool passes `isinstance(x, numbers.Number)` too - real
  # Jinja2's own `number` test answers True for `True`.
  def number? : Bool
    @raw.is_a?(Number) || @raw.is_a?(Bool)
  end

  def as_number : Crinja::Number
    raw = @raw
    return raw ? 1 : 0 if raw.is_a?(Bool)
    raw_as(Number)
  end
end
