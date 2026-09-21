# Crinja consolidation Phase 3 survey (dispatch-surface catalog, no code changed)

Date: 2026-09-21. Scope: survey/planning only - no migration, no runtime
code touched, no VERSION bump, no spec run. This is the Phase-3
counterpart to `SUGGESTED_CRINJA_NEXT_STEPS.md`'s Phase 2 survey:
it walks the ENTIRE remaining hand-rolled-first surface (not just one
slice) and produces a prioritized, risk-annotated candidate list, so
the next implementation rounds can spend their effort where duplication
is real instead of re-discovering the boundaries every time.

Inputs read in full before writing: `CRINJA_PILOT_REPORT.md` (Phase 1,
filters 1-4 including the selectattr NO-GO) and
`CRINJA_PHASE2_REPORT.md` (slice 1, arithmetic `+`/`-` + the strict
operand-class follow-up). Files walked: `expression_evaluator.cr`
(4,532 lines - `evaluate_expr` and every dispatch sub-piece),
`filter_engine.cr` (2,606 lines - the full `case filter_name` statement
plus the test/attr dispatch at the bottom), `conditional_evaluator.cr`
(2,641 lines), `comparison_evaluator.cr` (331 lines), `jinja_filters.cr`
(all 85 `Crinja.filter` registrations), and the fork's own
`src/lib/filter/collections.cr` (weirdbricks/crinja @
crystal-play-0.9.56) for the Jinja-builtin and `map`/`select*`/`min`/
`max`/`unique`/`sum`/`groupby` implementations. Caveat: this worktree
has no `lib/` checkout, so fork-internals claims below cite the Phase-1
report's verified findings and a direct fetch of `collections.cr` at
the pinned tag, not a local grep.

## Architecture recap: where the two engines actually meet today

Three distinct hand-rolled surfaces remain, and they are NOT equally
unfinished:

1. **`ExpressionEvaluator`'s whole-`{{ }}` dispatch is effectively done.**
   Per the Phase-2 report and re-verified by walking it: literals,
   ternaries, boolean `or`/`and`/`is`, comparisons (minus the
   `type_sensitive_comparison?` carve-out), `+`/`-` (with the strict
   operand-class gate), `*`/`/`/`//`, `~`, slices, indexed/dotted
   access, and - the load-bearing one - **whole `|` filter chains**
   (`evaluate_with_filter`, expression_evaluator.cr:4330) are all
   Crinja-first with the exact-previous-code fallback. The only
   non-delegated constructs are the bare `lookup(...)`/`query(...)`/
   `range(...)`/`dict(...)` calls (correctly: Crinja has no `lookup()`
   equivalent; Phase-2 rule 1) and the fallback bodies themselves
   (load-bearing by design).
2. **`FilterEngine`'s `case filter_name` statement is the big remaining
   duplication surface** - ~90 hand-rolled case branches. It is reached
   only when the Crinja-first chain attempt raises (lookup-headed
   chains, `to_datetime` heads, strict-undefined rescue paths, ...) or
   directly from `map()`'s inner dispatch (see below) and
   expression_evaluator.cr:4208's dotted-walk-with-filter-suffix path.
   Exactly four names delegate to Crinja today (`dict2items`,
   `combine`, `json_query`, `lists_mergeby`).
3. **`ConditionalEvaluator` already delegates its unhandled tail** and
   hand-rolls only special cases (details below). `ComparisonEvaluator`
   is fallback-only with a tiny operator surface.

One stale-comment hazard found while walking (fix whenever someone next
touches filter_engine.cr): the dict2items branch's comment (line ~769)
claims extract/mandatory/bool/ipaddr were "already-delegated names ...
resolved years ago" through `#delegate_to_crinja_filter`. False for
`extract` - it is a full hand-rolled case branch at line 1248. The
comment apparently means those names have Crinja-side *registrations*,
which is a different claim. Given how load-bearing the delegated-names
list is for planning, that comment should not be trusted as inventory.

## Q4 (flagged item): `map()`'s filter-application dispatch is DUAL-PATH, not shared

This was the survey's most important question, and the answer explains
tonight's bug shape directly. There are **two independent `map`
implementations, and which one serves a given call depends on whether
the enclosing chain's Crinja-first attempt succeeded**:

- **Crinja-first path:** the fork's native `Crinja.filter(:map)`
  (collections.cr) - for the filter-name form it resolves the callable
  once, then per item builds `Arguments` and calls
  `env.execute_call(filter, args)`, i.e. dispatch through the fork's
  `env.filters` registry (with the fork's hoisted-defaults
  optimization). Serves every chain whose whole-expression Crinja
  evaluate succeeds - which, post-Phase-2, is the COMMON case for
  plain `{{ x | map('extract', hostvars, 'k') | list }}` chains.
- **Fallback path:** FilterEngine's hand-rolled `map` case
  (filter_engine.cr:466) - for the filter-name form it re-parses the
  inner expression and **recurses into the hand-rolled `#apply` case
  statement per item** (line 503: `apply(item, inner_expr)`). Zero
  Crinja awareness: even a delegated name only helps here because its
  own case branch happens to call `#delegate_to_crinja_filter`.

Consequences, all observed in the wild rather than hypothesized:

- **Every behavioral fix to an `extract`-class filter must land twice.**
  Proven, not predicted: commit 21077616 ("Fix extract not raising on
  missing hostvars attribute via map()") touched BOTH
  `src/krikri/jinja_filters.cr` (the Crinja registration) AND
  `src/krikri/variable_substitutor/filter_engine.cr` (the hand-rolled
  case) in the same commit. Commits e7e1102d and 19fdc3f2 (both about
  `map('extract', ...)` errors surfacing from lazy vars / aborting the
  run) then had to build control flow on top of that dual
  implementation. This is the exact "same bug class fixed twice"
  pattern CLAUDE.md warns about, located precisely.
- **The two `extract` copies have ALREADY diverged semantically**, not
  just syntactically: the Crinja copy (jinja_filters.cr:1082) handles
  `HostVarsVarsDict` wrappers natively via
  `extract_hostvars_attribute` and words a plain-dict miss "object of
  type 'dict' has no attribute 'x'"; the hand-rolled copy
  (filter_engine.cr:1248) detects hostvars by object identity
  (`container.raw.same?(hostvars_raw)`) and words a plain-container
  miss differently. Same-name filter, different error text and
  different code path, selected by whether the enclosing chain happened
  to Crinja-succeed. The same asymmetry exists for `regex_findall`
  (whose `mat.size > 1` single-capture-group bug was fixed as two
  separate copies - filter_engine.cr:876's comment references
  "the same bug as jinja_filters.cr's own copy").
- **Coverage asymmetry:** a filter registered only on the Crinja side
  (`strftime`, `subelements`, `to_nice_yaml`, `shuffle`, `comment`,
  `mandatory`, `quote`, `root`, `items`) works in a plain
  Crinja-first chain but raises `UnknownFilterError` in a fallback
  chain (e.g. `lookup('pipe', ...) | strftime`). Not a migration
  candidate - a fallback-path coverage gap to log and decide on.

## The catalog

Classification per case branch: (a) does a Crinja-side equivalent
exist, (b) what is the actual implementation relationship, (c) is it
reachable per-item in a loop. The (b) column is what Phase 1 taught us
to check - "thin wrapper over shared core" (`json_query`-shaped) vs
"genuinely independent copy" (`combine`-shaped) vs "lives in the fork"
(`selectattr`-shaped, unfixable without editing the shard).

**Already delegated (Phase 1 complete):** `dict2items`, `combine`,
`json_query`, `lists_mergeby`/`list_mergeby`.

### Group A - genuinely independent duplicates (real duplication, the actual Phase-3 candidates)

| Name(s) | Crinja twin | Divergence history | Per-item reachability |
|---|---|---|---|
| `extract` | jinja_filters.cr:1082 | **Already diverged + already double-fixed** (21077616); hostvars handling and error wording differ per copy | HIGH - `map('extract', hostvars, ...)` is the canonical use |
| `regex_search`, `regex_findall` | jinja_filters.cr:1489/1529 | Double-bug history (`mat.size` bug fixed in both copies separately) | HIGH - `map('regex_findall', ...)` found live in prometheus roles |
| `items2dict` | jinja_filters.cr:1373 | None known; dict2items's twin, both sides recently spec-locked | LOW |
| `ternary` | jinja_filters.cr:284 | None known; hand-rolled side has explicit omit-sentinel handling to preserve | MEDIUM |
| `zip`, `zip_longest`, `product` | jinja_filters.cr:908 (macro)/922 | None known; independent list-math on each side | LOW |
| `combinations`, `permutations` | jinja_filters.cr:1035/1039 (own recursive helpers) | None known | LOW |
| `rekey_on_member` | jinja_filters.cr:1048 | None known; `duplicates=` semantics hand-rolled per side | LOW |
| `from_yaml_all` | jinja_filters.cr:1137 | None known; near-identical small bodies | LOW |
| `random` | jinja_filters.cr:1908 (fork-extended) | Fork side was recently live-verified against Jinja 3.1.6 (string-target semantics); hand-rolled side not | LOW |
| `relpath`, `log`, `pow` | jinja_filters.cr:981/990/995 | None known; note the kwarg-vs-positional arg-shape difference (`relpath(start='.')` vs positional) | LOW |

### Group B - shared-core thin wrappers (consolidation ALREADY happened at the FilterCore/IpAddrCore/Vault layer; bridging would be pure added overhead)

Both sides call the same core module; the hand-rolled case branch is
only arg-parsing + one core call. Migrating these to
`#delegate_to_crinja_filter` would wrap a call that internally
converts to JSON::Any anyway inside two MORE conversions - the exact
quadruple-conversion mistake the `json_query` round measured (~33x).
Verified shared: `regex_replace` (FilterCore.regex_replace),
`hash`/`password_hash`, `to_json`/`to_yaml`/`to_nice_json`,
`from_json`/`from_yaml`, `b64encode`/`b64decode`, `checksum`,
`urldecode`, `regex_escape`, `human_readable`/`human_to_bytes`,
`netmask_to_cidr`, `md5`/`sha1`, `expanduser`/`expandvars`,
`normpath`/`commonpath`, `to_uuid`, `union`/`difference`/
`intersect`/`symmetric_difference`, `path_join`, `splitext`,
`map_format`, `dirname`/`basename`, `type_debug`, the whole `ipaddr`
family (13 names, IpAddrCore), `vault`/`unvault` (Krikri::Vault),
`fileglob`/`realpath` (identical one-liners).

### Group C - Jinja-builtin duplicates where the twin lives in the fork

`upper`, `lower`, `capitalize`, `title`, `trim`/`strip`, `replace`,
`split`, `sort`, `unique`, `reverse`, `join`, `list`, `first`, `last`,
`min`, `max`, `length`/`count`, `sum`, `abs`, `int`, `float`, `string`,
`bool`, `default`/`d`, plus `select`/`reject`/`selectattr`/
`rejectattr` and `map` itself. The fork implements all of these
(collections.cr + core library), several recently hardened against
real Jinja 3.1.6 (`random`, `min`/`max` case-insensitivity, `groupby`,
`unique` attribute support). The hand-rolled copies are smaller and in
some cases LESS capable (`sort` without `attribute=`? `unique` without
`attribute=`/`case_sensitive`? - the fork's versions are supersets).
BUT: these are the hottest filters in real roles, frequently per-item
via `map('first')`/`map('int')`/`map('bool')`, and their hand-rolled
bodies carry krikri-specific semantics (FilterEngine's `default`
resolves variable-reference fallback args and the `default(x, true)`
falsy form; `int` has failure-default handling). See priorities.

### Group D - no Crinja equivalent exists (permanently hand-rolled)

Bare `lookup(...)`/`query(...)`/`range(...)`/`dict(...)` calls; the
register-result tests (`succeeded`/`failed`/`changed`/`skipped` - a
Crinja render has no access to krikri's register bookkeeping);
`to_datetime`'s tagged-hash datetime machinery on the hand-rolled side
(see below); the strict `+` operand-class gate and every fallback body.

### Group E - deliberately-different twins (consolidation = behavior decision, not implementation swap)

- **`to_datetime`**: hand-rolled side tags datetimes with a
  `DATETIME_TAG` hash so `-` arithmetic (and `.days` access) work
  through the fallback path; the Crinja registration produces a
  structured timedelta Hash instead. Phase 2 documented the shapes
  diverge; unifying means picking one contract for
  `to_datetime | to_datetime - ...` chains first.
- **`default`/`d`**: hottest filter in real roles; the hand-rolled
  version's variable-reference default argument (`default(other_var)`)
  and strict-undefined interplay have no clean expression through the
  bridge (kwargs arrive as strings; the undefined-ness of the DEFAULT
  ARGUMENT itself is part of the semantics). High risk, negative
  expected value.
- **ComparisonEvaluator's operator core** (`values_equal?`/
  `compare_values`): its numeric-string leniency (`"7" == 7` is true)
  is a deliberate pipeline artifact, and the
  `type_sensitive_comparison?` carve-out exists precisely because
  Crinja's typed answer is wrong for that shape. Reachable only as a
  fallback. Leave.

### ConditionalEvaluator (src/krikri/conditional_evaluator.cr)

Better-shaped than assumed: unknown-test and bare-call conditions
ALREADY delegate whole-condition to Crinja
(`{{ (condition) }}` at :849, the boolean-ternary trick at :270/:879),
with compile-time name validation consulting both engines
(:1453). What remains hand-rolled-first: `defined`/`undefined`/`none`,
`match`/`search` (own regex + anchoring), `version` (shares
`compare_versions` in jinja_filters.cr with the Crinja-side
registration - already one-table), `subset`/`superset`/`contains`,
`succeeded`/`failed`/`changed`/`skipped` (Group D - no Crinja
equivalent), the filesystem tests (`is_dir`/`is_file`/`is_link`/
`exists`/`file`/`directory`/`link`), truthiness, the type tests
(`mapping`/`sequence`/`boolean`/`number`/`string`/`iterable`/...), and
test-form comparisons. All of these are per-CONDITION (once per task),
never per-item, so the selectattr economics don't apply - but they are
also exactly the tests whose strict-undefined and register-result
semantics were hand-tuned against real rounds. Low value, non-trivial
risk: leave, except opportunistically (e.g. if a fork test registration
would let a special case be deleted wholesale).

## Prioritized candidate list

### Worth migrating (ordered safest/highest-value first)

1. **`items2dict`** - same shape as the dict2items pilot: independent
   twin registration, spec-locked contract, low-frequency (no per-item
   economics), existing bridge machinery unchanged. Risk: near-zero;
   check `items_to_dict`'s helper for other callers first (Phase-1
   lesson: `combine_hash` had a surprise second caller).
2. **`ternary`** - independent twin, tiny body, low-frequency. Risk:
   the hand-rolled omit-sentinel branch (`ternary('x', omit)`) must
   survive the swap; probe the Crinja registration's omit behavior
   first.
3. **`regex_search` + `regex_findall`** (one slice - they share the
   arg-parsing and regex-cache seam) - real double-bug history.
   Risk note: HIGH per-item reachability via `map('regex_findall',
   ...)` means bridge delegation would compound; see the seam note
   below - prefer unifying both sides onto ONE shared core over
   `#delegate_to_crinja_filter` for this pair.
4. **`extract`** - highest value (tonight's bugs, prior double-fix,
   already-diverged copies) and also the trickiest: the Crinja copy's
   `HostVarsVarsDict` path and the hand-rolled copy's identity-check +
   wording need a single contract, and it is THE per-item filter.
   Same seam recommendation as #3: a shared core (e.g.
   `FilterCore.extract` speaking JSON::Any, with hostvars-detection
   hoisted to the caller) rather than per-item bridge delegation.
   Probe both copies' behavior batteries (`hostvars` vs plain dict,
   list vs hash container, morekeys as string vs list, missing-key
   error texts) before touching anything.
5. **Group-A tail** (`from_yaml_all`, `zip`/`zip_longest`/`product`,
   `combinations`/`permutations`, `rekey_on_member`, `relpath`, `log`,
   `pow`, `random`) - each a small independent duplicate with a live
   Crinja twin and low frequency; batchable as cheap follow-ups, low
   individual payoff. Watch the arg-shape differences (`relpath`'s
   `start=` kwarg vs positional).

**Seam rule this survey adds to Phase 1/2's caveat list:** the right
consolidation seam is per-item-reachability-dependent. For a filter
reachable through `map(...)` (extract, regex_findall, ternary, the
builtins), prefer **shared-core unification** (both case branch and
Crinja registration call one FilterCore helper - zero bridge cost,
the Group-B pattern) over `#delegate_to_crinja_filter` (one
JSON::Any<->Crinja::Value roundtrip PER CALL, and per ITEM when
reached via map - the Phase-1 selectattr bench already measured the
bridge base at ~14 us/call and the fork's own per-item dispatch at
~3.4 us/item, both far above the hand-rolled per-item ~5 ns). Bridge
delegation stays the right tool only for low-frequency,
Crinja-native-end-to-end filters (`dict2items`-shaped).

### Worth benchmarking before deciding

- **`map()`'s inner dispatch itself.** The survey's numbers already
  argue AGAINST the two obvious rewrites: delegating per item through
  the bridge costs ~14 us/item (worse than the fork's own 3.4
  us/item); delegating the whole `map(...)` call wholesale to
  `Crinja.filter(:map)` pays one bridge conversion but then the
  fork's per-item `env.execute_call` internally - same 675x-per-item
  class Phase 1 rejected. The recommended alternative (shared cores
  per filter, above) needs no benchmark - it is strictly
  zero-overhead. Only if someone insists on single-dispatch should a
  bench be run, and it will confirm the no.
- **Group-C Jinja builtins** (`int`/`bool`/`string`/`join`/`first`/...)
  - migrating them onto the fork's (often MORE correct) registrations
  would import real improvements (`min`/`max` case-insensitivity,
  `unique(attribute=)`, `random` string semantics), but onto the
  hottest, most per-item-heavy path, and the hand-rolled copies carry
  krikri-specific arg semantics. Decision rule: migrate one ONLY when
  a real-role divergence shows the hand-rolled copy is wrong, and
  then via shared-core (or benchmark first if per-item).
- **ConditionalEvaluator's type tests** (`mapping`/`sequence`/...)
  - delegable to the fork's test library, per-condition so no per-item
  concern, but the hand-rolled versions encode strict-undefined
  behavior; only worth it if a divergence shows up. Low value.

### Known not worth it

- **Group B entirely** (shared-core wrappers, ~35 names incl. the
  whole ipaddr family): consolidation already exists one layer down;
  bridging adds the json_query quadruple-conversion tax for zero
  dedup.
- **`select`/`reject`/`selectattr`/`rejectattr`**: Phase-1 NO-GO stands
  (fork-native via `env.tests`, ~675x per-item, unfixable without
  editing the shard).
- **`default`/`d`**: hottest filter, variable-ref default args and
  strict-undefined semantics don't survive the bridge; negative
  expected value.
- **`to_datetime` + the tagged datetime/`-` machinery**: the twins'
  output shapes are deliberately different (Group E); unification is
  a strictness contract decision, not an implementation swap.
- **Bare `lookup()`/`query()`/`range()`/`dict()` calls** and the
  register-result tests: no Crinja equivalent (Phase-2 rule 1).
- **ComparisonEvaluator's operator core and every fallback body**:
  load-bearing by design (Phase-2 rule 2).
- **The strict `+` operand-class gate**: exists because the vendored
  Crinja is lenient where real Ansible raises; it must run BEFORE any
  Crinja attempt and can never be delegated away.

## Recommended next steps (for whoever implements Phase 3)

1. Land the stale-comment fix (filter_engine.cr:769's delegated-names
   claim) with the first real change.
2. Slice 1 = `items2items`... `items2dict` (pilot-shaped, builds
   confidence), Slice 2 = `ternary`, Slice 3 = the regex pair via
   shared-core, Slice 4 = `extract` via shared-core (probe-first, the
   divergence inventory already partially exists in 21077616's specs).
3. Keep the Phase-1/2 discipline per slice: divergence probe script
   committed alongside, every divergence arbitrated against local
   ansible-core, one revertible commit, VERSION bump, full suite,
   throwaway-worktree benchmark - replacing the benchmark step with a
   parity check where the shared-core seam makes the bridge tax
   moot.
4. Log the fallback-path coverage gap (Crinja-only names unreachable
   in lookup-headed chains) in `KNOWN_MISSING.md` as a deliberate
   limit or open gap - the survey's finding, that decision belongs to
   a round with real-host evidence, not to this doc.

---

# Slice 1 report: `items2dict` migrated onto Crinja (2026-09-21)

The survey's #1 candidate, executed as the survey itself prescribed.
Scope: exactly the one dispatch branch - `FilterEngine`'s `items2dict`
case stops calling the hand-rolled `#items_to_dict` helper (deleted)
and routes through the native `Crinja.filter(:items2dict)` registration
(`jinja_filters.cr:1373`) via `#delegate_to_crinja_filter`, the same
pilot shape `dict2items` resolved with in Phase 1. The stale
delegated-names comment at the old `filter_engine.cr:769` is fixed in
the same commit (the survey's recommended step 1). VERSION
0.9.1236 -> 0.9.1237.

## Method (the Phase-1/2 discipline, per slice)

1. **Probe before touching code**:
   `scripts/crinja_corpus/probe_items2dict_divergence.cr` - 19 cases
   (basic/empty, all four kwarg combos, collision order, malformed
   elements, int/bool/null values, non-string keys, non-list inputs,
   the real-role `vars_result.results` shape), each run through the
   hand-rolled dispatch and through the exact
   `#delegate_to_crinja_filter` mechanics the migration would use.
2. **Arbitrate every divergence against real ansible-core 2.19.11**
   (local `ansible-playbook`), same as every prior round.
3. Implement, full suite, benchmark old-tree-vs-new-tree via a
   throwaway worktree at the pre-change commit
   (`scripts/crinja_corpus/bench_items2dict_pilot.cr`, N=100,000,
   release build).

## Divergences found (pre-change probe, arbitrated against real Ansible)

17 of 19 cases matched. Both divergences were **in the hand-rolled
copy's disfavor** - the migration is strictly a correctness win, not a
trade:

| Case | Real Ansible 2.19.11 | OLD hand-rolled | NEW via Crinja | Verdict |
|---|---|---|---|---|
| `{'key': 1, 'value': 'x'}` (non-string key) | `{"1": "x"}` - key stringified | silently skipped the element (the helper's `.as_s?` gate) | `{"1": "x"}` | **Strictly more correct** - fixes a silent data-drop toward real Ansible |
| `null \| items2dict` | raises (`items2dict requires a list, got <class 'NoneType'> instead`) | silently returned `{}` | raises | **Strictly more correct** - a null no longer masquerades as an empty mapping |

One class deliberately NOT converged: the silent skip of a non-dict or
missing-`key_name`-field list element. Real Ansible 2.19 raises on a
malformed element, but krikri's tolerance is a shared, spec-locked
contract on BOTH sides (a single malformed element must not fail the
whole filter; locked in `spec/unit/filter_engine_spec.cr`), so the
delegated path preserves it unchanged via the Crinja registration's
own skip. Same decision the dict2items pilot made. Undefined-input
rejection still happens upstream in
`Krikri.undefined_filter_chain_source`, before any filter runs.

Post-change the probe reports **0 diverged of 19** by construction
(both paths it compares ARE the same Crinja registration now); its
pre-change output is the divergence inventory above. Two regression
specs pin the arbitrated verdicts in `filter_engine_spec.cr` (int-key
stringification, null-input raise).

Full suite after the change: **5343 examples, 6 failures / 2 errors**
- exactly the documented nondeterministic baseline (`is_test_aliases_
spec` cluster, `x509_csr_info_spec` tmp-file race). No new failures,
no spec modified except the two additions.

## Performance: real numbers

`crystal run --release` of `bench_items2dict_pilot.cr`, N=100,000
(8-entry `vars_result`-shaped list per call), old tree = pre-change
commit via throwaway worktree. Both sides are noisy (GC-driven
spikes); per-call ns across repeated rounds:

| Expression | OLD hand-rolled | NEW via bridge | Delta |
|---|---|---|---|
| `items2dict` (plain) | ~300-380 ns | ~5-10 us typical, spikes to ~35-50 us | ~15-25x slower |
| `items2dict(key_name=..., value_name=...)` (kwargs) | ~1.0-1.5 us | ~8-10 us typical, spikes to ~50 us | ~7-10x slower |

Exactly the cost class the survey predicted for a `dict2items`-shaped
bridge delegation: one JSON::Any <-> Crinja::Value roundtrip PER CALL,
~14 us/call base - and, critically, paid once per expression, never
per item, because `items2dict` is a list->dict reducer that cannot
appear inside a `map()` body. In absolute terms ~5-10 us against task
costs measured in tens of milliseconds; it will not show up in any
real round's timing. The spike variance (both sides, including the
unchanged kwargs path) is allocator/GC noise at this call frequency
and does not change the verdict.

## Verdict and what's next

Slice 1 stands as the survey's template: pilot-shaped, low-frequency,
probe-first, both divergences resolved toward real Ansible, bridge tax
proven acceptable for the seam. The remaining slices keep their
survey-assigned seams unchanged:

- Slice 2 (`ternary`): still `#delegate_to_crinja_filter`-shaped;
  probe the omit-sentinel branch first.
- Slices 3/4 (`regex_search`/`regex_findall`, `extract`): still
  shared-core, NOT bridge - per-item reachability via `map(...)` makes
  delegation compound per item.

---

# Slice 2 report: `ternary` migrated onto Crinja (2026-09-21)

The survey's #2 candidate, on the seam slice 1's verdict confirmed for
it: `FilterEngine`'s `ternary` case stops running its hand-rolled
pick-a-branch copy and routes through the native
`Crinja.filter(:ternary)` registration (`jinja_filters.cr:284`) via
`#delegate_to_crinja_filter`. The flagged risk - the hand-rolled
omit-sentinel branch (`ternary('x', omit)`, found via linux-system-
roles' journald `(is_ostree | d(false)) | ternary(
'ansible.posix.rhel_rpm_ostree', omit)`) - was probed FIRST and
survives: the bare-`omit` argument text is mapped to OMIT_SENTINEL
*before* delegation (resolving it as a variable would yield null -
`#resolve_base_expression` has no `omit` concept), and the
registration passes its arguments through untouched, so the sentinel
string flows out exactly like real Ansible's omit object and is
dropped by the same `substitute_task_params` contract as before.
VERSION 0.9.1237 -> 0.9.1238.

## Method (the Phase-1/2 discipline, per slice)

1. **Probe before touching code**:
   `scripts/crinja_corpus/probe_ternary_divergence.cr` - 24 cases
   (true/false/0/1/0.0 conditions, empty string, the `"0"`/`"false"`/
   `"False"`/`"no"` string conditions, empty and non-empty lists and
   dicts, null condition, null + third arg, omit in the true branch,
   omit in the false branch, the quoted `'omit'` literal, the sentinel
   string AS the condition, missing-arg forms, an unchosen undefined
   variable, a variable-reference branch), each run through the
   hand-rolled dispatch and through the exact bridge mechanics the
   migration would use.
2. **Arbitrate every divergence against real ansible-core 2.19.11**
   (local `ansible-playbook`), reading the installed filter plugin's
   own Python source for the tie-breakers.
3. Implement, full suite, ameba on touched files.

## Divergences found (pre-change probe, arbitrated against real Ansible)

19 of 24 cases matched - including every omit-sentinel case, both
directions, plus the quoted `'omit'` literal and the sentinel string
as a condition value. Five diverged, all fixed in the old copy's
disfavor:

| Case | Real Ansible 2.19.11 | OLD hand-rolled | NEW via Crinja | Verdict |
|---|---|---|---|---|
| condition `"0"` / `"false"` / `"False"` | truthy - Python `bool()` on a non-empty string picks `true_val` (probed: `A3/A4/A5 -> yes`) | falsy - the old `truthy?` helper treats those spellings as false and picks the wrong branch | truthy | **Strictly more correct** - the old copy silently picked the wrong branch for string conditions |
| `ternary('yes')` (missing `false_val`) | raises (`ternary() missing 1 required positional argument: 'false_val'`) | silently returned null | raises, same message shape | **Strictly more correct** - a malformed call no longer masquerades as an empty value |
| `ternary()` (missing both) | raises (`... missing 2 required positional arguments: 'true_val' and 'false_val'`) | silently returned null | raises, same message shape | same |

One shared gap NOT in the old-vs-new divergence set was also fixed,
because the probe's third-arg battery exposed it against the oracle:
real Ansible's signature is `ternary(value, true_val, false_val,
none_val=None)` - a None condition returns `none_val` ONLY when a
third argument was passed (`null | ternary('yes','no','n/a')` -> `n/a`,
probed), while a plain null WITHOUT a third argument still falls to
`false_val` (`null | ternary('yes','no')` -> `no`, probed - the None
check is gated on `none_val is not None`). Both earlier copies
silently ignored a third argument. The registration now honors
`none_val` with exactly that gating, on both engines at once.

Two deliberate non-convergences, both documented:
- A null condition WITHOUT a third argument picks `false_val` on both
  sides - which matches real Ansible's probed behavior too, so no
  gap; the only deviation is that krikri's lenient engine resolves an
  UNDEFINED condition variable to null (real Ansible raises
  strict-undefined before the filter ever runs) - the standing
  engine-wide leniency contract, unchanged.
- Arguments are now resolved eagerly (both branches) instead of only
  the chosen one. Real Jinja evaluates call arguments eagerly too, so
  this is toward the oracle, and the lenient null resolution of an
  unchosen undefined variable leaves the picked branch identical
  (probed: `ternary('yes', undef_var)` on true -> `yes` on both).

Post-change the probe reports **0 diverged of 24** by construction
(both paths it compares share the registration now); its pre-change
output is the divergence inventory above. Regression specs pin every
arbitrated verdict in `filter_engine_spec.cr` (string-condition
truthiness, both omit directions + the quoted literal, `none_val`
form, missing-arg raises, variable-reference branches), and a
Crinja-side `none_val` spec was added to `crinja_renderer_spec.cr`.
As a side effect of the new specs, `filter_engine_spec.cr` now
requires `jinja_filters.cr` directly - the delegated-name specs
(dict2items/items2dict/ternary) no longer depend on require order to
pass in an isolated `crystal spec spec/unit/filter_engine_spec.cr`
run (that isolation gap had been silently masking 10 errors).

Full suite after the change: **5348 examples, 6 failures / 2 errors**
- exactly the documented baseline (`is_test_aliases_spec` cluster,
`x509_csr_info_spec` tmp-file race). No new failures. Ameba clean on
every touched file (the two findings in `jinja_filters.cr` - a
pre-existing shadowing at :1144 and a pre-existing formatting quirk
at :2312 - reproduce identically at the pre-change commit).

## Cost note (no bench script this slice)

No dedicated benchmark was committed: `ternary` is a per-condition
scalar selector, not a list reducer - it runs once per expression,
and the corpus shows it inside module params and `{% if %}` gates,
never per item inside a `map()` body. Its cost class is therefore
slice 1's measured one-shot bridge base (~5-10 us/call) at a far
lower call frequency than `items2dict`, invisible against real task
costs. If a future round finds `map('ternary', ...)` in a live role,
the shared-core seam (both case branch and registration calling one
helper) is the survey-prescribed upgrade path.

## Verdict and what's next

Slice 2 lands with the flagged risk discharged: the omit sentinel
survives in both directions, arbitrated against real ansible-core
and pinned by spec. Remaining slices keep their survey-assigned
seams: slices 3/4 (`regex_search`/`regex_findall`, `extract`) are
still shared-core, NOT bridge - per-item reachability via `map(...)`
makes delegation compound per item.
