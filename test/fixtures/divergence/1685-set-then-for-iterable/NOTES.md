# #1685 - a {% set %} target is undefined when a later tag in the SAME
# template uses it (for iterable / if condition)

- Issue: https://github.com/weirdbricks/krikri/issues/1685
- Class: behavioural bug (ansible exit 0, krikri exit 2)

**What diverged.** Inside one template string, a name assigned with
`{% set %}` was "undefined" when used as a `{% for %}` iterable or in an
`{% if %}` condition. It worked in the body of a `for` loop.
ansible-core 2.21.6 renders all three tasks of the fixture (`ab`, `big`,
`XaXb`); krikri failed the first two at arg finalization with
"Error while resolving value for 'msg': 'n' is undefined" (exit 2 against
real's 0). Real impact: a `copy: content:` template starting with
`{% set hits = ... %}` and looping `{% for path in hits | ... %}` never
wrote its file.

**Root cause.** The strict `{% %}` block-tag pre-scan
(`scan_strict_block_tags_for_undefined` in variable_substitutor.cr) tracked
`{% if %}`/`{% for %}` structure but never recorded a `{% set %}` target, so
any LATER tag in the same text referencing the target raised
"'n' is undefined" before the engine - which honors set bindings - ever
rendered. The scan now records set target roots (`x`, tuple-form `a, b`,
attribute-form `ns.attr` -> `ns`, block assign `set x`) for the rest of the
text, while references BEFORE the set still raise.

**Fixture.** The issue's three-task repro playbook verbatim (debug only, so
the case mutates nothing).

Captured with `bin/krikri-capture-case` against pinned ansible-core 2.21.6.
