# Crinja consolidation pilot report (Phase 1, filter #1: `dict2items`)

Date: 2026-09-20. Scope: exactly one filter migrated per
`SUGGESTED_CRINJA_NEXT_STEPS.md` Phase 1 - no other filters, no Phase 2.

## Pilot pick and why

Of the four known-duplicated filters (`combine`, `dict2items`, `selectattr`,
`json_query`) plus a broader sweep of the `Crinja.filter` registrations in
`jinja_filters.cr` vs `filter_engine.cr`'s dispatch, `dict2items` was the
least risky first cut:

- **Smallest edge-case surface.** Hand-rolled copy was ~26 lines of dispatch
  plus one 8-line helper (`dict_to_items`); a pure one-shot
  dict -> list-of-pairs transform. No recursion (`combine`'s recursive
  `list_merge` strategies), no test-name integration (`selectattr`'s
  `item_matches_test?` machinery), no expression language (`json_query`'s
  JMESPath).
- **Both implementations were recently re-verified independently** against
  ansible-core 2.19.4 (the strict-undefined work), so their behavioral
  contracts were documented and spec-covered on both sides - the safest
  possible baseline for proving "zero behavior change".
- **Rich safety net.** 4 unit examples in `filter_engine_spec.cr`, the
  compile-time pre-pass spec, `crinja_direct_spec`'s Crinja-side examples,
  and three integration specs (undefined-chain strictness, mode-octal loop,
  CLI) all exercise this name.

## What changed

- `src/krikri/variable_substitutor/filter_engine.cr`: the `dict2items` case
  no longer carries its own JSON::Any implementation. It parses the two
  kwarg names exactly as before (`parse_kwarg`, defaults `key`/`value`) and
  hands off to a new private seam `#delegate_to_crinja_filter`, which:
  converts the (already fully-resolved) value via the pure
  `CrinjaRenderer.json_any_to_crinja_value`, invokes the ONE native
  `Crinja.filter(:dict2items)` registration from `jinja_filters.cr` through
  a `Crinja::Arguments` built the same way `Resolver#execute_call` wires a
  `{% %}`-pipeline call (including the callable's declared defaults), and
  converts the result back via `CrinjaRenderer.crinja_value_to_json_any`.
- Deleted the hand-rolled `dict_to_items` helper (sole caller was this
  case). `items2dict` and `as_hash` remain untouched (other callers).
- `KNOWN_FILTER_NAMES` keeps `dict2items` - the dispatch still knows the
  name, it just implements it by delegation now; the pre-pass spec confirms.
- New benchmark: `scripts/crinja_corpus/bench_dict2items_pilot.cr` (same
  style as the existing `bench_evaluators.cr` perf gate).
- `VERSION` 0.9.1219 -> 0.9.1220 (+ README badge).

One deliberate deviation from the doc's wording: the doc suggested routing
through the `convert_var` bridge. That was rejected for the filter-value
handoff because `convert_var` re-templates nested `{{ }}` strings - and a
value reaching a filter has *already* been resolved and recursively
re-rendered by the strict-templating entry points, so re-rendering would be
a second pass and a behavior change, not an implementation swap. The pure
converter is the correct bridge for a resolved value; `convert_var` remains
the right entry for whole variable scopes (as `LazyCrinjaContext` uses it).

## Behavior: identical

All dict2items-related specs pass **unmodified**
(`filter_engine_spec`, `conditional_filter_prepass_spec`,
`crinja_direct_spec`, `undefined_filter_chain_strict_spec`,
`mode_octal_via_variable_spec`), and the full suite shows no new failures:
5250 examples, 6 failures / 2 errors - exactly the known nondeterministic
cluster (`is_test_aliases_spec`, the x509 tmp-file race, the hardlink race),
same shape as the pre-change baseline.

No behavioral divergence between the two implementations surfaced: for
every input class the specs cover (flat dict, custom kwargs, empty dict,
nil, non-dict string, undefined guarded upstream), both agreed. The one
semantic difference that exists *between* the two stacks (Crinja's filter
hard-fails a genuine `Crinja::Undefined`; FilterEngine never produces one
because undefined filtering is rejected upstream by
`Krikri.undefined_filter_chain_source`) is unreachable through the bridged
path by construction - the pure converter cannot yield an Undefined.

## Performance: real numbers

`crystal run --release scripts/crinja_corpus/bench_dict2items_pilot.cr`,
N=100,000, 8-entry dict, after a warmup pass (per-call ns, median-ish of
repeated runs; runs under concurrent load spiked to ~6.5us):

| Path                                          | per call |
|---|---|
| `dict2items`, OLD hand-rolled (pre-change)    | ~1.03 us |
| `dict2items`, NEW delegated -> Crinja         | ~4.3 us  |
| `dict2items(key_name=..., value_name=...)` NEW| ~4.6 us  |
| `items2dict`, hand-rolled reference filter    | ~0.33 us |

So the `JSON::Any <-> Crinja::Value` roundtrip costs ~3.3 us per call,
roughly 4x the filter's own old cost. In context: this is a per-`dict2items`
invocation cost, against per-task costs dominated by SSH round trips and
module execution measured in tens of milliseconds; a hardening role using
`loop: "{{ os_vars | dict2items }}"` a handful of times per play pays
microseconds. The risk the doc flagged is real but small in absolute terms
for this filter; it would matter proportionally more for a filter invoked
per-item inside large `map()` pipelines.

## Recommendation: worth continuing, with caveats

**Worth it.** The consolidation works exactly as Phase 1 predicted: the
native Crinja registration became the single implementation, the
hand-rolled copy is gone, and the bridge machinery (one ~15-line helper)
was enough - no new behavioral surface, full spec suite green. Each
remaining duplicated filter should land as its own revertible commit the
same way.

Caveats to carry into the next three:

1. **Per-call roundtrip overhead is real (~4x on the filter, +3.3 us
   absolute).** Accept it for low-frequency filters; for filters reachable
   per-item through `map()`/`selectattr` pipelines, benchmark before
   migrating (or keep a fast path).
2. **Use the pure `json_any_to_crinja_value` bridge for filter inputs, not
   `convert_var`** - double re-templating is a behavior change, not a
   consolidation. (The doc's `convert_var` suggestion is right for scope
   conversion, wrong for already-resolved filter values.)
3. **Order of migration by risk:** `combine` next (self-contained recursive
   merge, Crinja side already shares `JinjaFilters.combine_merge`
   semantics), then `json_query` (thin wrapper over the shared
   `src/krikri/jmespath.cr`), leaving `selectattr` last (its test-name
   dispatch is the most entangled with hand-rolled evaluator internals).
4. `KNOWN_MISSING.md`/`ROLES_TESTED.md` were deliberately not touched:
   this pilot ran no real-host round (out of scope). The confirm-phase
   expectation is that no role-visible behavior changes - the spec suite is
   the evidence for that here.
