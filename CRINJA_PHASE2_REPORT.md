# Crinja consolidation pilot report (Phase 2, slice 1: arithmetic `+`/`-` constructs)

Date: 2026-09-20. Scope: exactly one narrow slice of
`SUGGESTED_CRINJA_NEXT_STEPS.md` Phase 2 - the two remaining
arithmetic constructs in `ExpressionEvaluator`'s `{{ }}` dispatch
(top-level `+` chains and top-level `-` subtraction), migrated onto
Crinja-first delegation. Nothing else. No real-host round was run
(out of scope; see the recommendation).

## What was surveyed

`ExpressionEvaluator` (`src/krikri/variable_substitutor/
expression_evaluator.cr`, 4,371 lines) is much further along the
Phase-2 path than the Phase-2 description implies. Its whole-`{{ }}`
dispatch is already "try Crinja first, fall back to the exact
previous hand-rolled code on any raise" for essentially every
construct: ternaries (with and without `else`), boolean `or`/`and`/
`is`, bare boolean/numeric/quoted-string literals, comparisons
(except the `type_sensitive_comparison?` carve-out), `*`/`/`/`//`,
`~` concatenation, leading-paren expressions, filter chains,
literal arrays/dicts, Python slices, indexed access, dotted access,
and simple variable lookups. The hand-rolled bodies all remain, but
as fallbacks, not primary paths.

What was NOT yet delegated, found by walking the dispatch:

1. **Top-level `+` chains** (`evaluate_plus` + `resolve_plus_operand`
   + `combine_plus`, plus the literal/mult-div/recursive operand
   resolvers and the shared `retemplated_lookup_value` machinery) -
   the dominant real-role string-building shape
   (`'https://...' + ver + '/sums.txt'`) and the list-accumulator
   idiom (`acc | default([]) + [item]`).
2. **Top-level `-` subtraction** (`evaluate_minus` +
   `combine_minus`, including the datetime/timedelta tagged-hash
   special case).
3. Bare `lookup(...)`/`query(...)`/`range(...)`/`dict(...)` calls -
   NOT candidates: Crinja has no `lookup()` equivalent at all, so
   delegation would be pure overhead (every call would raise into
   the fallback) and zero consolidation. Left untouched.
4. The fallback bodies themselves (`evaluate_value_or_and`,
   `type_sensitive_comparison?`, etc.) - by design, not candidates;
   the fallbacks are load-bearing.

## Pilot pick and why

The `+` and `-` dispatch branches, together, as one slice:

- **They are the last arithmetic constructs still hand-rolled-first.**
  Everything around them in the dispatch already tries Crinja first,
  so this is the narrowest remaining category with an actual
  consolidation payoff - after it, `evaluate_expr`'s operator chain
  is fully Crinja-first.
- **Small, spec-locked behavioral contract.** Bool-as-int coercion
  (`true + true` == "2", locked at `expression_evaluator_spec.cr:1395`
  and `:1396` for both `+` and `-`), `*`/`/`-over-`+`/`-` precedence
  (`2 + 3 * 4` == "14"), the quote-ended-`+`-chain guard
  (`'https://...v' + prometheus_version + '/...'`, locked), and the
  list re-templating battery (`motd_info__default + motd_info__custom`)
  all exercise these branches today.
- **The Crinja side already exists and was purpose-extended for
  krikri.** The vendored fork's `Plus`/`Minus` operators
  (`src/lib/operator/plus.cr`/`minus.cr`) carry krikri's own patches:
  Bool-as-arith-number (`True == 1`, matching `combine_with_bool_
  coercion`), `Finalizer.stringify` string-concat fallback (matching
  `combine_plus`'s lenient else branch), TimeDelta arithmetic
  (matching the datetime `-` case), and Python slice support. This is
  the same "two independent copies that happen to agree" situation the
  Phase-1 `combine` round found.
- **Doesn't touch `VariableLookup#format_value`** - the output
  formatting stays exactly where the doc says it must; both new
  branches format through it, like every other converged construct.

`-` was included with `+` (rather than `+` alone) because the two
share `resolve_plus_operand`, sit in adjacent dispatch branches, and
the divergence probe covered both; splitting them would have meant
two commits over one shared seam for no extra safety.

## Method (same as Phase 1)

1. **Probe before touching code**:
   `scripts/crinja_corpus/probe_plus_minus_divergence.cr` - 31 `+`
   shapes and 14 `-` shapes (real-role idioms included), each run
   through the current hand-rolled dispatch and through a simulation
   of the delegation (`CrinjaRenderer#evaluate_value!` +
   `VariableLookup#format_value`, with the rescue-to-hand-rolled
   fallback the real implementation would have).
2. **Arbitrate every divergence against real `ansible-playbook`**
   (ansible-core 2.19.11, locally) - the same discipline as the
   Phase-1 reports.
3. Implement, re-probe (post-change the probe reports 0/0 by
   construction - the "current dispatch" it compares against IS the
   delegation now; its pre-change output is the divergence inventory
   below), full suite, benchmark old-tree-vs-new-tree via a throwaway
   worktree at the pre-change commit.

## Divergences found (pre-change probe, arbitrated against real Ansible)

Everything matched except the classes below. **No spec locks any of
them** (verified by grep before deciding). Real-Ansible's verdict
comes from a local `ansible-playbook` run of each case.

`+` (4 classes in 9 of 31 shapes):

| Case | Real Ansible 2.19.11 | OLD hand-rolled | NEW via Crinja | Verdict |
|---|---|---|---|---|
| `8080 + 2.5` (int + float) | **8082.5** (numeric add) | `"80802.5"` - string concat; `combine_plus` lacks the `{Int64, Float64}` case its `-` twin has | `"8082.5"` | **Strictly more correct** - fixes a live hand-rolled bug toward real Jinja |
| `null_var + 'x'` (present-but-null operand) | **raises** (`NoneType` operand) | silently drops the null (`"x"`) | `"Nonex"` | Lateral - real Ansible fails the task; both engines silently produce text; neither matches |
| `host + omit` | **raises** (`_OmitType` operand) | silently drops the omit (`"web1"`) | sentinel text `"web1__crystal_ansible_omit__"` | Same class as above |
| `list1 + 3`, `d1 + d2` (container + non-concatenand) | **raises** | garbage concat (`["a","b"]3`, JSON-shaped) | garbage concat (`['a','b']3`/append, Python-repr-shaped) | Lateral - both garbage, different garbage |

Missing/undefined operands (`missing_var + 'x'`, `port + missing_var`)
**match** - Crinja stringifies `Undefined` as `""`, same as the
hand-rolled null-concat path.

`-` (1 class in 2 of 14 shapes):

| Case | Real Ansible 2.19.11 | OLD hand-rolled | NEW via Crinja | Verdict |
|---|---|---|---|---|
| `(a \| to_datetime) - (b \| to_datetime)` bare, no `.days` | errors storing a raw timedelta (`Type 'timedelta' is unsupported`), though `.days` in-expression works | silently `""` - the operands round-trip through stringified `Time` reprs, so the hand-rolled datetime special case was ALREADY dead code on this shape | structured `{"days":1,"seconds":0,...}` | **Strictly more useful** - matches the shape `crinja_value_to_json_any` already documents for downstream `.days`/`.seconds` access |

Every non-numeric `-` shape (strings, lists, null, plain-string
timestamps) raises in Crinja and falls back to the hand-rolled path
identically. The parenthesized `.days` form (`expression_evaluator_
spec.cr:1534`) was already routed through Crinja by the leading-paren
construct before this change and is unaffected.

The lateral classes are reported, not silently accepted: they are all
cases where **real Ansible raises and neither engine matched it
before or after**. Making them raise like real Ansible would be a
deliberate strictness change (a `+`/`-` operand that is null/omit/
non-concatenand failing the task), which is Phase-2-scope policy, not
implementation-swap scope - noted in the recommendation.

## What changed

- `expression_evaluator.cr`'s `evaluate_expr`: the `split_top_level_
  minus` and `split_top_level_plus` dispatch branches now try
  `render_via_crinja_value` (the raw-value path - a `+` chain can
  produce a container, so the scalar-only `#render_via_crinja` is
  wrong here) and format through `@lookup.format_value` on success;
  any raise falls back to the unchanged `evaluate_plus`/
  `evaluate_minus`. Same depth-guarded, revertible pattern as every
  prior converged construct. Both hand-rolled bodies and their
  operand resolvers stay (they are the fallback, and
  `resolve_plus_operand` is also mult/div's fallback).
- New: `scripts/crinja_corpus/probe_plus_minus_divergence.cr` (the
  probe), `scripts/crinja_corpus/bench_plus_minus_pilot.cr` (the
  bench).
- VERSION 0.9.1223 -> 0.9.1224 (+ README badge).

## Behavior: no spec-locked change

All evaluator specs pass unmodified - `expression_evaluator_spec`
(including the bool-coercion, precedence, quote-guard, and re-render
batteries), `comparison_evaluator_spec`, `conditional_evaluator_spec`,
`crinja_renderer_spec`, `crinja_direct_spec`, `crinja_strict_
undefined_spec` (401 examples). Full suite: **5276 examples, 6
failures / 2 errors** - exactly the documented nondeterministic
baseline (`is_test_aliases_spec` cluster, x509 tmp-file race;
`is_test_aliases_spec` passes in isolation, confirming the known
require-ordering artifact). No new failures.

## Performance: real numbers

`crystal build --release` of `scripts/crinja_corpus/bench_plus_minus_
pilot.cr`, N=100,000, per-call ns, median-ish of 3 alternating old/new
rounds (old tree = pre-change commit via a throwaway worktree, same
script). First-draft runs under concurrent load showed ~2x spikes on
everything including the unchanged reference - the alternating
sequential rounds below were stable to within a few percent.

| Expression | OLD hand-rolled | NEW Crinja-first | Delta |
|---|---|---|---|
| `'https://...' + ver + '/sums.txt'` (3-seg string build) | ~2,320 ns | ~2,680 ns | +16% |
| `host + '.example.com'` (string + string) | ~1,730 ns | ~1,860 ns | +8% |
| `port + 10` (numeric add) | ~1,570 ns | ~1,475 ns | ~6% **faster** |
| `emptylist + ['x']` (list concat) | ~2,790 ns | ~2,330 ns | ~17% **faster** |
| `port + ratio` (int + float) | ~2,440 ns | ~1,850 ns | ~24% **faster** (and now correct) |
| `port - 10` (numeric subtract) | ~1,330 ns | ~1,285 ns | unchanged |
| `port - null_var` (Crinja raises -> fallback) | ~2,210 ns | ~16,900 ns | ~7.7x (double evaluation) |
| `items2dict` (hand-rolled reference filter) | ~300 ns | ~295 ns | unchanged |

This is the opposite of the Phase-1 filter pattern, and the reason is
structural: a whole-expression Crinja evaluate pays ONE conversion
level (the lazy context), while the hand-rolled `+`/`-` path's own
operand resolution (`resolve_plus_operand`'s literal -> mult/div ->
recursive-check chain, the lookup, and the re-templating probe) costs
more than Crinja's cached-AST evaluate for the numeric/list shapes.
Only multi-segment string builds pay (+8-16%, the Crinja render
itself), in absolute terms ~0.4 us/call against task costs measured
in tens of milliseconds.

The one real hazard is the **fallback double evaluation**: when
Crinja raises (non-numeric `-` operands), the call pays the full
Crinja attempt AND the full hand-rolled path - ~17 us. That shape is
a role bug in real terms (real Ansible fails the task outright), and
it cannot compound (it is per-call, not per-item), but it is the
number to watch if this pattern is extended to constructs where
Crinja commonly raises - there, delegation is pure overhead plus a
double-eval penalty. That is exactly why the bare
`lookup(...)`/`query(...)` calls were NOT delegated.

## Recommendation: Phase 2 is worth continuing, with two hard rules

**Worth it.** The slice landed with zero spec changes, one live
hand-rolled bug fixed toward real Jinja (int + float), and
performance that is flat-to-faster on most shapes. The
"Crinja-first, exact-previous-code fallback" pattern transfers
cleanly from filter dispatch (Phase 1) to whole-construct dispatch,
using only existing machinery.

Rules the next slices must keep:

1. **Only delegate constructs where Crinja succeeds on the common
   shapes.** The bench's fallback row (~7.7x, +14.8 us) is what a
   wrong candidate looks like: pure double-eval overhead on every
   call. This rules out the bare `lookup(...)`/`query(...)` calls
   permanently (no Crinja equivalent exists to succeed).
2. **The fallbacks are load-bearing - do not delete them in the same
   breath as the swap.** Strict bracket-index failures, unknown
   filters, re-templating edge cases, and the lenient concat classes
   above all live in the hand-rolled bodies. Deleting them (the
   "shrink to a formatting shell" end state) is a separate,
   deliberate strictness/behavior decision, not an implementation
   swap.

What remains before Phase 2 could be called done (not this pilot's
scope): the same treatment probed for any remaining non-delegated
constructs (none of consequence were found beyond the bare-call
forms), a real-host round confirming role-visible behavior is
unchanged, and the deliberate decision on whether the lenient
concat/omit divergences should become real-Ansible errors under a
strictness flag. KNOWN_MISSING.md/ROLES_TESTED.md were deliberately
not touched (no real-host round was run).
