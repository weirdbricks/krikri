# #1686 - a template ending in {{ list }} after {% set %} typed as str (ansible: list); {% for %} output typed as int (ansible: str)

- Issue: https://github.com/weirdbricks/krikri/issues/1686
- Repro: the issue's own minimal playbook (no role), `-i localhost, -c local`
- Diverged on krikri 0.9.3014 vs ansible-core 2.21.5

**What diverged.** For set_fact values built from block-tag templates,
krikri re-typed the rendered TEXT by shape while real ansible-core 2.19+
types the value by the template's RUNTIME output chunks:

- `b: "{% set l = ['a','b'] %}{{ l }}"` - one output chunk (the `{% set %}`
  emits nothing) whose value is a list: ansible stores the LIST, krikri
  stored the repr string, so the following `loop: "{{ b }}"` failed with
  "The `loop` value must resolve to a 'list', not 'str'."
- `f: "{% for i in [1,2] %}{{ i }}{% endfor %}"` - two output chunks ("1",
  "2"): ansible joins them into the STR "12", krikri's set_fact coercion
  re-typed the numeric-looking text into the int 12.

The a/c/d/e cases (whole-span expressions, and `{% if true %}{{ 5 }}{% endif
%}` whose single chunk is an int) already agreed.

**Why.** krikri treated any `{%`-bearing value as "never natively typed"
(the pre-2.19 whole-AST-is-one-output-node rule). ansible-core 2.19's native
environment concatenates runtime output chunks instead: exactly one
non-stringified chunk keeps its native type; every multi-chunk render and
every literal-text/str chunk finalizes a plain str (live-verified vs 2.21.5,
including `{% if true %}5{% endif %}` -> str, `{% for i in [1] %}{{ i }}{%
endfor %}` -> int, `{# c #}{{ 5 }}` -> int, `{% set s = '5' %}{{ s }}` ->
str, `{% if false %}{{ 5 }}{% endif %}` -> None).

**Fix.** JinjaRenderer captures each `{{ }}` output node's pre-finalize
value during the render (a derived engine copy + a finalize wrapper, so
block-local `{% set %}`/`for` names are visible); the set_fact
(native_containers) substitution marks a single native chunk's JSON on the
NATIVE_TYPED_PREFIX wire and every other block-tag output as a plain str,
replacing set_fact's shape re-coercion for these shapes.

**Fixture.** `playbook.yml` is the issue's repro verbatim; nothing mutates
the host.
