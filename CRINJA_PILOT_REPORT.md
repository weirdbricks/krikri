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

---

# Filter #2: `combine` (Phase 1 continues)

Date: 2026-09-20. Scope: exactly one filter (`combine`), on its own branch
(`crinja-filter-consolidation-combine`), same discipline as the pilot.

## What the pilot's "already shares combine_merge semantics" actually meant

Verified before touching anything: the two implementations did NOT share a
helper. FilterEngine#combine_hash (JSON::Any) and jinja_filters.cr's Crinja
registration (Crinja::Value, via JinjaFilters.combine_merge +
list_merge_values) were two independent, hand-ported copies that
mode-for-mode happened to agree - the Crinja side's own comment said
"Ported from FilterEngine#combine_hash". So this migration deleted real
duplication: the Crinja registration became the single implementation for
the name.

## What changed

- `filter_engine.cr`'s `combine` case: the kwarg parsing (dedicated regex,
  NOT #parse_kwarg - real roles write `recursive=True` unquoted) stays
  verbatim, but the `positional_args.reduce { combine_hash(...) }` merge is
  replaced by #delegate_to_crinja_filter, with the resolved positional dicts
  passed as varargs and `recursive`/`list_merge` as pre-built Crinja values.
  #combine_hash itself REMAINS in the file: lists_mergeby's core still
  merges with it (the pilot report's "self-contained recursive merge"
  assumption was slightly wrong - combine's helper has a second in-tree
  caller).
- `#delegate_to_crinja_filter` was generalized, not reinvented: the
  original single-target/string-kwargs form became a thin overload; the
  general form takes pre-built `Crinja::Variables` plus an optional
  `Array(JSON::Any)` of positional varargs (Crinja::Arguments carries
  varargs natively). The string overload's doc notes why bool kwargs must
  go through the general form: the text "false" is truthy to Crinja's
  `truthy?`, so `recursive` must arrive as a real Bool.
- `jinja_filters.cr`'s `JinjaFilters.list_merge_values`: the `_rp` dedupe
  no longer calls `Crinja::Value#to_json` (see divergence below) - it
  converts each element through the pure
  CrinjaRenderer.crinja_value_to_json_any and serializes THAT. Same
  compact, insertion-ordered JSON text the hand-rolled dedupe compares.
- New benchmark: `scripts/crinja_corpus/bench_combine_pilot.cr`.
- VERSION 0.9.1220 -> 0.9.1221 (+ README badge).

## Behavior: identical, plus one latent Crinja-side crash bug fixed

All combine-related specs pass **unmodified** - including
`lazy_dict_templating_spec`'s battery (recursive deep-merge, every
list_merge mode against real ansible-core 2.19 expectations,
unquoted `recursive=True`) and `crinja_direct_spec`'s Crinja-side example.
Full suite: 5250 examples, 6 failures / 2 errors - exactly the known
nondeterministic cluster (is_test_aliases_spec, x509 tmp-file race,
hardlink race), no new failures.

**One genuine bug surfaced, and was fixed rather than papered over** - not
a divergence between the two krikri implementations but a latent defect in
the vendored Crinja shard that the migration exposed: the shard's
`Value#to_json(JSON::Builder)` calls `start_document` on the builder it is
handed, but `Object#to_json` has already opened that document, so ANY
standalone `Value#to_json` crashes ("Starting document before ending
previous one"). The Crinja-side combine's `list_merge='append_rp'`/
`prepend_rp` dedupe (`uniq(&.to_json)`) hit exactly that - meaning
`{{ d | combine(o, list_merge='append_rp') }}` in a real .j2 template has
been a live crash all along, on the Crinja side only. The hand-rolled side
never hit it because JSON::Any#to_json is fine. Fixed in
`list_merge_values` via the pure converter (see What changed); the shard
itself is untouched (it's a shards dependency, not vendored source).

## Performance: real numbers

`crystal build --release` of
`scripts/crinja_corpus/bench_combine_pilot.cr`, N=100,000, 5-key/2-nested
dicts, warmup pass, both trees (old = pre-change commit via a throwaway
worktree, same script, median-ish of repeated runs):

| Path                                        | OLD hand-rolled | NEW delegated -> Crinja |
|---|---|---|
| `combine` 1 positional                      | ~4.3 us | ~8.6-9.2 us |
| `combine` recursive=True                    | ~4.8 us | ~8.9-9.4 us |
| `combine` recursive+list_merge='append_rp'  | ~6.5 us | ~11.3-12.3 us |
| `items2dict` (hand-rolled reference filter) | ~0.3 us | ~0.45-0.53 us |

So the roundtrip costs ~2x on the filter (~+4-6 us absolute), i.e. a
smaller relative penalty than dict2items' ~4x - combine's own merge work
is heavier, so the fixed conversion cost is proportionally smaller. Same
verdict as the pilot: per-invocation microseconds against per-task costs
measured in tens of milliseconds. `combine` is frequently chained 2-4
times in one expression (os_hardening), which multiplies the absolute
number but stays in the tens-of-microseconds range.

## Recommendation: confirms the pilot, two revisions

1. The bridge generalizes cleanly to multi-argument filters - varargs were
   already supported by `Crinja::Arguments`; only the helper's signature
   needed widening. No new machinery for `json_query`.
2. Revision to the pilot's caveat list: "self-contained" is not a property
   you can assume - `combine`'s helper had a second caller
   (lists_mergeby), so check ALL callers of a helper before declaring its
   death; `combine_hash` stays until `lists_mergeby` is migrated (and
   migrating `lists_mergeby` onto the Crinja registration would then let
   both go).
3. New caveat: migrating a filter onto the Crinja registration imports
   that registration's own latent bugs as FilterEngine bugs - the suite
   caught this one immediately, but treat any Crinja-side code path the
   hand-rolled side never exercised as UNVERIFIED until the bridged specs
   prove it (the `_rp` crash had been sitting in the Crinja-side combine
   since its registration, unreached by any spec that used it standalone).

---

# Filter #3: `json_query` (Phase 1 continues)

Date: 2026-09-20. Scope: exactly one filter (`json_query`), on its own
branch (`crinja-filter-consolidation-jsonquery`), same discipline as the
prior two.

## Whether "thin wrapper over shared jmespath.cr" held

Held, cleanly - unlike `combine`'s "self-contained" assumption, this one
was correct on inspection: both the hand-rolled `filter_engine.cr` dispatch
and the native `Crinja.filter(:json_query)` registration already called
the exact same `Krikri::JMESPath.evaluate` (`src/krikri/jmespath.cr`) -
no JMESPath-layer duplication existed to find. The only duplication was
the thin per-side wrapper: argument extraction plus "invalid JMESPath
expression" error-message formatting, independently written on each side
but producing the same text. Deleting the hand-rolled wrapper and routing
through `delegate_to_crinja_filter` (unchanged from the `combine`
migration's generalized form - varargs carry the expression) removed real
but small duplication, and `require "../jmespath"` came out of
`filter_engine.cr` since it no longer calls the module directly.

## Behavior: identical

All `json_query`-related specs pass unmodified (`jmespath_spec.cr`,
`filter_engine_spec.cr`'s json_query examples, `crinja_direct_spec.cr`'s
`{% %}`-path example), full suite shows no new failures beyond the known
nondeterministic cluster. No divergence surfaced - both sides raised the
identical wrapped error text for an invalid expression, and the missing-
expression guard (kept in `filter_engine.cr`, since a Crinja vararg is a
truthy value even when empty-string) matches the old contract exactly.

## Performance: a real, larger regression than filters #1-2 - root cause found

`crystal run --release` of `bench_json_query_pilot.cr`, N=100,000, a
4-entry package-fact-shaped list, old tree (pre-filter-3 commit, built in
a throwaway worktree) vs new tree, both release builds:

| Path                                             | OLD hand-rolled | NEW delegated |
|---|---|---|
| `json_query('[*].name')` (list projection)       | ~824 ns  | ~27,766 ns |
| `json_query('[?state=='present'].name')`         | ~1,474 ns | ~4,085 ns |
| `items2dict` (hand-rolled reference filter)      | ~235 ns  | ~278 ns |

The second query's ~2.8x is in line with filters #1-2's ~2-4x roundtrip
tax. The FIRST query's ~33x is not, and does NOT come from delegation
overhead in general - it comes from a delegation-specific mistake in
THIS filter's registration body. `Crinja.filter(:json_query)`'s block
receives `target` as a `Crinja::Value` (already converted once by
`delegate_to_crinja_filter`'s inbound bridge), then immediately converts
it BACK to `JSON::Any` via `crinja_value_to_json_any` to hand to
`Krikri::JMESPath.evaluate` (a JSON::Any-based API), then converts the
JSON::Any RESULT forward to `Crinja::Value` to return it - which
`delegate_to_crinja_filter`'s outbound bridge then converts back to
JSON::Any again for the FilterEngine caller. That is FOUR conversions
per call (two of them wholly avoidable), not the two filters #1-2 pay,
because `dict2items`/`combine`'s filter bodies operate on `Crinja::Value`
natively end-to-end - `json_query`'s body round-trips through JSON::Any
internally because the JMESPath engine only speaks JSON::Any. The
`[*].name` query's cost is dominated by this quadruple conversion of a
list-of-dicts value; the `state=='present'` query converts a smaller
intermediate (filtered result), which is why its overhead looks close to
filters #1-2's baseline instead.

This was not fixed in this migration - the registration itself (not the
new delegation code) is what pays the extra round-trip, and it existed
before this migration too (the Crinja side's own `.j2`-template callers
already paid this same double-conversion; it just had no companion
hand-rolled implementation to compare against until now). Filed as a
found-not-fixed item: `Krikri::JMESPath` could gain a `Crinja::Value`-
native entry point to remove the internal round-trip, but that is scope
creep for a Phase-1 consolidation pass and is real, separate work.

## Recommendation for `selectattr` (last filter)

1. **Check for this same "converts back internally" pattern before
   migrating `selectattr`.** Its Crinja registration is more complex
   (per-item test dispatch) - if it round-trips JSON::Any internally per
   item the way `json_query` does per call, the per-call overhead could
   compound over list size rather than being a flat filter-call tax like
   the first three. Profile before merging, not just before-and-after at
   the whole-filter level.
2. The "thin wrapper, shared backend" pattern (true here) is cheaper to
   verify AND cheaper at runtime (only the outer bridge pays roundtrip
   cost) than the "genuinely independent implementations, now merged"
   pattern (`combine`) - if `selectattr`'s hand-rolled `item_matches_test?`
   machinery turns out to be its own thing rather than calling a shared
   test-dispatch helper, expect a `combine`-shaped migration (bigger,
   riskier) rather than a `json_query`-shaped one (small, clean).
3. Absolute magnitude still doesn't matter for normal per-task usage
   (27us against tens-of-ms task costs), but flag it explicitly in the
   final Phase-1 wrap-up rather than let a 33x number pass silently -
   caveat #1 in the pilot report ("benchmark before migrating a filter
   reachable per-item") was written for exactly this kind of surprise.

---

# Filter #4: `selectattr` - found: NOT worth migrating (Phase 1 concludes)

Date: 2026-09-20. Scope: exactly one filter (`selectattr`, together with
the `rejectattr`/`select`/`reject` names that share its machinery), same
discipline as the prior three. This is the migration's first NO-GO
outcome: the hand-rolled implementation stays in place, no runtime code
changed, no VERSION bump. The benchmark and the divergence probe that
justify this are committed
(`scripts/crinja_corpus/bench_selectattr_pilot.cr`,
`scripts/crinja_corpus/probe_selectattr_divergence.cr`).

## The "most entangled with hand-rolled evaluator internals" claim, verified

Not true in the sense everyone assumed - and the truth is worse for
migration purposes. There is no shared test registry anywhere:

- FilterEngine's `selectattr_matches?`
  (`src/krikri/variable_substitutor/filter_engine.cr`) is its own small
  case statement (`equalto`/`eq`/`==`, `ne`/`!=`, `undefined`, `truthy`,
  `sameas`, else -> defined-presence check). It does NOT call into
  ConditionalEvaluator/ComparisonEvaluator's test handling for `when:`
  conditions, which dispatch their own independent `case test_name`
  statements (falling back to a Crinja render only for tests it never
  special-cased).
- What selectattr DOES share is the sibling list-test filters:
  `select`/`reject`'s `item_matches_test?` delegates to
  `selectattr_matches?`, and `selectattr`/`rejectattr` share
  `apply_selectattr` (one implementation, `invert` flag). So any
  migration touches four filter names, not one.
- The Crinja side needs no registration in `jinja_filters.cr` at all:
  the fork's core library (`weirdbricks/crinja`,
  `src/lib/filter/collections.cr`'s `select_reject_attr` macro) already
  ships native `selectattr`/`rejectattr`/`select`/`reject`, dispatching
  each item through `env.tests`. Three test-dispatch implementations
  exist in total, none shared: FilterEngine's, ConditionalEvaluator's,
  and the fork's env.tests registry.

So the expected difficulty classification inverted: not a
`json_query`-shaped thin-wrapper migration, and not even quite a
`combine`-shaped merge of two in-tree copies - one of the two
implementations lives in a shard dependency, which the `combine` round
already ruled out touching.

## Performance: the per-item profile filter #3 asked for, and it's bad

`crystal run --release scripts/crinja_corpus/bench_selectattr_pilot.cr`,
N=20,000, 8-field hostvar-shaped dict entries, warmup pass
(`selectattr('state', 'equalto', 'present')`; the prototype delegates
through the exact `#delegate_to_crinja_filter` bridge mechanics to the
fork's native registration):

| List size | OLD hand-rolled | NEW delegated -> fork |  delta |
|---|---|---|---|
| 4 entries   | ~1,240 ns | ~14,109 ns  | ~11x |
| 50 entries  | ~1,508 ns | ~173,272 ns | ~115x |
| 500 entries | ~3,770 ns | ~1,720,089 ns | ~456x |

The overhead is NOT a flat per-call tax: subtracting the ~14 us base
(the per-call bridge conversion, in line with filters #1-2), the
delegated path pays ~3.4 us PER ITEM where the hand-rolled path pays
~5 ns - a ~675x per-item cost, dominated by the fork's per-item
`env.execute_call(test, args)` dispatch (a fresh `Crinja::Arguments`
allocation and registry lookup for every list entry). This is exactly
the compounding-over-list-size failure filter #3's report predicted,
just with the root cause in the fork's registration body rather than a
JSON::Any roundtrip (the list converts across the bridge exactly once).

In real terms: a single `selectattr` over a 500-entry inventory-shaped
list costs 1.7 ms where the hand-rolled path costs 4 us - and real
roles do not use selectattr once. openstack.ansible-hardening chains
`selectattr(...) | selectattr(...) | sum(attribute=..., start=[])` over
package lists; inventory/hostvar-shaped pipelines chain
`selectattr | map | first`. Each chain link multiplies the per-item
tax, pushing a single expression into the several-ms range and a
playbook's worth of them into visible latency. This fails the go/no-go
bar outright.

## Behavior: also not preservable through delegation (checked before deciding)

Performance alone would be borderline-enough to warrant weighing, but
behavior settles it. `probe_selectattr_divergence.cr` runs four
spec-locked or documented behaviors through the delegated path; ALL
FOUR diverge from the hand-rolled path:

1. **`==` as a test-name spelling** (locked by
   `filter_engine_spec.cr:446`, `selectattr('stat.exists', '==', True)`):
   the fork's test registry deliberately does not register the symbol
   spellings as bare names - the delegated path raises
   `UnknownFeatureError: no test with name "==" registered`.
2. **selectattr's no-test default**: the hand-rolled path falls back to
   a `defined` presence check (keeps present-but-falsey entries); the
   fork falls through to truthiness (drops them) - a silent,
   data-dependent result difference.
3. **Re-templating of `{{ }}`-bearing attribute values** (locked by
   `filter_engine_spec.cr:409`, the openstack.ansible-hardening
   `stig_packages_rhel7` fix): the delegated path compares the raw
   `"{{ security_package_state }}"` text and matches 0 items where the
   hand-rolled path matches 1. This one is NOT FIXABLE through any
   registration: the re-templating needs the *calling FilterEngine
   instance's own* `@vars` scope, which no Crinja filter can reach
   (`#delegate_to_crinja_filter` builds standalone arguments against
   `CrinjaRenderer.shared_environment`).
4. **Unknown test name**: the hand-rolled path falls back to the
   defined-presence check by design (documented at the dispatch site);
   the fork raises.

Fixing 1, 2 and 4 would mean editing the fork (a shard dependency,
ruled out in the `combine` round) or shadowing its registration with a
krikri-owned reimplementation - which is not consolidation at all, just
relocating the hand-rolled code across a type boundary while paying the
bridge tax and still losing behavior 3. There is no version of this
migration that preserves exact behavior.

## Verdict

**No-go, on both prongs independently.** The hand-rolled
`apply_selectattr`/`selectattr_matches?` machinery stays, and stays
correct: it is the only implementation of its documented contract.
What would need to change before this filter could migrate safely:

- The fork's `selectattr` registration would need to stop dispatching
  per-item through `env.execute_call` (resolve the test callable once,
  or accept a pre-resolved predicate), removing the ~3.4 us/item tax;
- The fork's test registry would need `==`/`!=` and the other operator
  spellings registered as bare names (real Jinja2 3.1.6's own
  `jinja2/tests.py` does register them);
- A scope-aware bridge would need to exist so a Crinja filter can
  re-template `{{ }}`-bearing attribute values against the calling
  engine's vars (and selectattr's no-test `defined` default and
  unknown-test fallback would need to be reproduced) - at which point
  the "consolidation" would still be a rewrite, not a merge.

Full suite after the decision: 5276 examples, 6 failures / 2 errors -
the known nondeterministic cluster, unchanged; no runtime code was
modified.

---

# Phase 1 complete: overall wrap-up

Date: 2026-09-20. All four originally-duplicated filters assessed
(3 migrated, 1 refused); per `SUGGESTED_CRINJA_NEXT_STEPS.md`, Phase 1
asked exactly this question and the answer is now known per filter.

| Filter | Outcome | Roundtrip tax | Behavior surprises |
|---|---|---|---|
| `dict2items` (#1) | MIGRATED | ~4x per call (+3.3 us) | none |
| `combine` (#2) | MIGRATED | ~2x per call (+4-6 us) | latent `Value#to_json` crash in the shard's `_rp` dedupe, found + fixed around the registration |
| `json_query` (#3) | MIGRATED | up to ~33x per call (quadruple conversion inside the registration; documented, not fixed - out of scope) | none |
| `selectattr` (#4) | NOT MIGRATED (evidence-based refusal) | ~675x per item (~3.4 us/item) - scales with list size | all four spec-locked behaviors diverge through the only available (fork) registration |

Net verdict: **Phase 1 was worth doing, and worth stopping where it
stopped.** The three migrations deleted genuine duplication, kept the
full suite green without behavior changes, and left one reusable,
 battle-tested seam (`#delegate_to_crinja_filter`) plus a repeatable
method (benchmark first, divergence-probe the registration, revertible
commit each). Their costs are real but flat per call and lost against
per-task costs. Selectattr's refusal is the other half of the same
win: the identical discipline caught, before any runtime code changed,
a case where "consolidation" would have meant shipping a 675x per-item
regression AND breaking four locked behaviors - the original plan's
"benchmark before migrating a filter reachable per-item" caveat doing
precisely the job it was written for.

Residual debts, for anyone picking Phase 2 up: json_query's 33x is
still unfixed (a `Crinja::Value`-native JMESPath entry point would
remove it), and selectattr's migration remains blocked on the fork
(per-item execute_call, missing operator-spelling tests, and the
scope-aware re-templating bridge) - none of it worth taking without a
real-host round that demonstrates need.

---

# Post-Phase-1 fix: json_query's quadruple-conversion tax eliminated (branch `fix-jsonquery-double-conversion`)

Date: 2026-09-20. This resolves the "found-not-fixed" item left by filter
#3 and named again in the Phase-1 wrap-up's residual debts.

## Option chosen: FilterEngine dispatches json_query directly to the shared JMESPath wrapper (option 3), not a Crinja::Value-native JMESPath (option 1)

The three candidate fixes were investigated for real:

1. **`Crinja::Value`-native JMESPath entry point** - rejected. The
   evaluator is ~600 lines of JSON::Any-typed logic (projection
   semantics, comparisons, 23 functions, truthiness rules) plus the
   parser/tokenizer. Making it polymorphic over the value type means
   retyping every line of that, against a 150-line behavior-locked
   spec, to save conversions on a path whose absolute cost is
   microseconds. It would also keep the JSON::Any engine in parallel
   (every existing caller and spec - `jmespath_spec.cr`,
   `filter_engine.cr`'s own contract - speaks JSON::Any), i.e. the
   exact "two engines, same bug class twice" pattern this codebase
   already fights. Rewrite-shaped, `selectattr`-grade risk, for a
   perf win option 3 delivers with ~15 lines.

2. **Cheaper conversion functions** - rejected as cost-shuffling, not
   elimination. `crinja_value_to_json_any` /
   `json_any_to_crinja_value` must materialize a full new
   `Hash(String, JSON::Any)` / `Array(Crinja::Value)` tree because the
   two worlds use different container types; there is no subset-read
   shortcut for a target whose whole shape JMESPath may traverse.

3. **Stop routing the `{{ }}` path through the Crinja registration at
   all** - CHOSEN. The insight from filter #4's assessment applies
   here too: the delegation bridge only makes sense when the filter
   body genuinely needs `Crinja::Value` semantics. json_query's body
   does not - it immediately converts back to JSON::Any for the
   JMESPath engine. So:

   - `Krikri::JMESPath` gains `evaluate_json_query(expression, data)`
     (`src/krikri/jmespath.cr`), which wraps any engine error in the
     filter-style "json_query: invalid JMESPath expression" message.
     This keeps the error text single-sourced, which was the real
     consolidation win of filter #3; the remaining per-side code is
     the trivial arg extraction + missing-expression guard both sides
     already had pre-consolidation.
   - FilterEngine's `json_query` dispatch (filter_engine.cr) calls
     that wrapper directly on its own JSON::Any value - **zero
     conversions**, strictly cheaper than even the pre-consolidation
     hand-rolled path (which paid the same direct call but had no
     shared wrapper).
   - The `Crinja.filter(:json_query)` registration
     (jinja_filters.cr) remains for the real `.j2`-template path,
     whose `Crinja::Value` target genuinely must be bridged; it now
     pays exactly the two irreducible conversions (target in, result
     out) instead of four, and evaluates through the same shared
     wrapper.

The delegation machinery itself (`#delegate_to_crinja_filter`) is
untouched and still serves `dict2items`/`combine`.

## Behavior: identical

All json_query specs pass unmodified (`jmespath_spec.cr` covers both
dispatch paths' happy shapes plus the invalid-expression task failure;
the wrapped error text now comes from the one shared wrapper). Full
suite: 5276 examples, 6 failures / 2 errors - the known
nondeterministic cluster (`is_test_aliases_spec`, `x509_csr_info_spec`),
no new failures. Ameba on the touched files: no new findings (the 3 in
`jinja_filters.cr` are pre-existing on the base commit).

## Performance: before/after (`scripts/crinja_corpus/bench_json_query_pilot.cr`, N=100,000, release, same tree)

| Query | BEFORE (delegated) | AFTER (direct) | Delta |
|---|---|---|---|
| `json_query('[*].name')` (list projection)  | ~3,016 ns | ~1,050 ns | ~2.9x faster |
| `json_query('[?state == 'present'].name')`  | ~3,602 ns | ~1,997 ns | ~1.8x faster |
| `items2dict` (hand-rolled reference)        | ~251 ns   | ~271 ns   | unchanged (noise) |

Note on the historical ~33x/~27,766 ns figure: that was measured on the
tree as it stood at the filter-#3 migration; later unrelated changes to
the conversion path had already shrunk it to the ~3 us measured here
immediately before this fix. The structural problem (four conversions
per call) was real and is what this fix removes; the remaining ~1 us on
the projection query is the JMESPath engine itself, with zero
conversion overhead.

The `.j2`-template path keeps its two irreducible bridge conversions
(measured only implicitly - the bench exercises the `{{ }}` path); a
`Crinja::Value`-native JMESPath remains the only way to remove those,
and stays not worth a rewrite per the option-1 analysis above.
