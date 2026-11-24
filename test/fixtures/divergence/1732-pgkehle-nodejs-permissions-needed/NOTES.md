# #1732 - pgkehle.nodejs: missing attribute read reported as a NoneType ordering TypeError

- Issue: https://github.com/weirdbricks/krikri/issues/1732
- Role: `pgkehle.nodejs` v2.0.1, `tasks/main.yml:59-61` ("Determine if the permissions are needed")
- Class: output gap (the task's error message differs)

**What diverged.** With `enable_gui` false the `setcap` task is skipped, so
`results_cap` is a result dict without `stdout`. Real ansible fails the
`set_fact` at that attribute READ:

```
Error while resolving value for 'differs': object of type 'dict' has no attribute 'stdout'
```

while krikri resolved `results_cap.stdout` to JSON null and then failed the
order comparison instead:

```
Error while resolving value for 'differs': Error rendering template: '>=' not supported between instances of 'NoneType' and 'int'
```

**Why.** The lenient krikri-jinja render cannot order a lenient `Undefined`
against an int, so `ExpressionEvaluator#evaluate_expr_operator` fell back to
the hand-rolled `ComparisonEvaluator`, which resolves an unresolvable operand
to null (`resolve_json` -> nil). Real Jinja2 raises where the undefined value
is consumed, and ansible wraps that read failure in the args-finalization
chain. The comparison fallback now asks the same strict-undefined probe every
other span-level failure uses before handing the expression to
`ComparisonEvaluator`, so a consumed miss fails with ansible's wording while a
genuinely incomparable operand keeps the TypeError (`{{ 'x' >= 1 }}`,
`none_var >= 1`).

**Fixture.** The role's two task YAML entries verbatim, with `when: false` on
the `setcap` task: the role only runs it when `enable_gui` is true, which is
also what leaves `results_cap` without a `stdout`. Nothing on the host is
touched.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`, from this directory.
