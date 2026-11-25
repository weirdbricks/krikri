# #1822 - inofix.yapkg: a failed variable render is a template error, not a conditional one

- Issue: https://github.com/weirdbricks/krikri/issues/1822
- Role: inofix.yapkg (galaxy) from round `logs___1795626220` /
  round29927212 (ubuntu, krikri 0.9.3119)
- Class: output gap - the error wording and the caused-by Origin differ.

## What diverged

The role's first task is guarded by a `when:` list whose second clause reads
`yapkg_names`, a role var whose own value is
`'{{ yapkg__names | list + yapkg_list.rstrip(";").split(";") }}'`. Resolving
it dies on an operand TypeError, because `yapkg_list` (a `{% for %}` over an
empty list) renders to None and `None.rstrip` is undefined.

Real words that failure the way it words every failed template render,
`Error rendering template: can only concatenate list (not "UndefinedMarker")
to list`, and the chain's caused-by Origin is the FAILING VALUE's
declaration (`roles/inofix.yapkg/vars/main.yml:12:14`). Krikri called it a
conditional-evaluation failure (`Error while evaluating conditional: ...`)
and pointed the caused-by Origin at the `when:` clause token instead.

## Fix

`evaluate_when` now asks `value_failure_var_origin` whether a single variable
in scope renders to exactly this operand-type failure: if one does, the
failure is a template render ("Error rendering template: ...") and the chain
pins that value's own declaration; otherwise the clause's own unbraced
expression failure keeps `Error rendering expression: ...` (the wording real
prints for `when: "[1] + 'x'"`, live-verified). The braced `{{ }}` form's
operand TypeError gets the same template wording - it previously crashed the
run with an unhandled exception - and an undefined NAME inside the braces
keeps the conditional wording. An `until:` clause draws the same
template-vs-expression line (live-verified for both forms).

**Fixture.** The role's `tasks/main.yml`, `vars/main.yml` and
`defaults/main.yml` are verbatim; the play's `become: true` is dropped since
the failing `when:` is evaluated before any escalation. `expected.out` was
captured with `bin/krikri-capture-case` from real ansible-core 2.21.6.
