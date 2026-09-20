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
forms), and the deliberate decision on whether the lenient
concat/omit divergences should become real-Ansible errors under a
strictness flag.

## Real-host confirmation (2026-09-20, post-merge, round 901500-901514)

Ran a 15-role confirmation round (`itigoag.packages`,
`geerlingguy.{docker,nginx,apache,mysql,postgresql,certbot,repo-epel}`,
`Stouts.{nginx,grafana,mongodb,rabbitmq}`,
`dev-sec.{os-hardening,mysql-hardening}`, `konstruktoid.hardening`) on
Atlantic.net against the merged `a03e3bff` build, deliberately weighted
toward roles known to build URLs/version strings via `+` concatenation
or do datetime arithmetic. Result: **4 CLEAN, 11 DIVERGENT - zero of
the 11 attributable to this change.**

Every divergence traced to one of three pre-existing, unrelated causes,
confirmed by diffing task-for-task output between engines:

- **A pre-existing cosmetic recap-counting artifact** (7 roles:
  `itigoag.packages`, all 6 `geerlingguy.*`): `ok:`/`changed:`/`TASK`
  lines are byte-identical in content and count between engines: the
  `PLAY RECAP` `ok=` total differs by exactly 1, the same "usual
  artifact" already noted against `geerlingguy.nginx` in
  `ROLES_TESTED.md` before this change existed.
- **Already-documented, unrelated krikri gaps**: `dev-sec.os-hardening`
  (pre-existing `NoneType`-vs-`str` conditional type mismatch, task
  content identical bar banner padding), `konstruktoid.hardening`
  (pre-existing role-side UFW/conntrack lockout, both engines affected
  identically - this run's python side hit the documented 15-minute
  timeout from that same lockout).
- **Pre-existing role/environment failures affecting real Ansible too**:
  `geerlingguy.repo-epel` (RedHat-only role on an Ubuntu host, fails
  identically on both engines - matches its existing `ROLES_TESTED.md`
  row) and `itigoag.packages`'s own failing task (`ansible.builtin.package`
  arg finalization erroring on a `state:` value shaped as a list -
  identical error text and identical failure on both engines, a
  role/package-fact-shape issue, not an engine bug).

No arithmetic-shaped divergence, no new failure class, and no role that
was previously CLEAN came back divergent for a reason connected to `+`/
`-`. `ROLES_TESTED.md`/`KNOWN_MISSING.md` intentionally not updated -
every role's status and root cause here already matches its existing
row; nothing changed.

## Strict +/- operand classes (2026-09-20, post-confirmation follow-up)

Implemented the four lenient-garbage classes from "Divergences found"
as hard failures matching real Ansible - plus a fifth class this
section CORRECTS the earlier report about.

### Correction: missing/undefined operands DO raise on real Ansible

The "Divergences found" section claimed `missing_var + 'x'` /
`port + missing_var` "match" because "Crinja stringifies Undefined as
''". That was wrong. Re-verified directly against the same local
ansible-core 2.19.11 with a minimal playbook (`debug: msg: "{{
missing_var + x }}"`, default strictness, no env overrides):

    fatal: [localhost]: FAILED! => {"msg": "Task failed: Finalization of
    task args for 'ansible.builtin.debug' failed: Error while resolving
    value for 'msg': 'missing_var' is undefined"}

Same for `-` (`missing_var - x` → `'missing_var' is undefined`). The
prior session's suspicion was right; the report's claim was the red
herring. Missing/undefined operands are now IN scope, and krikri
raises for them too.

### Real Ansible's verdict per class (2.19.11, exact texts)

| Class | Real Ansible raises with |
|---|---|
| `missing_var + x` | `'missing_var' is undefined` |
| `null_var + x` | `unsupported operand type(s) for +: 'NoneType' and '_AnsibleTaggedStr'` |
| `x + null_var` | `can only concatenate str (not "NoneType") to str` |
| `host + omit` | `unsupported operand type(s) for +: '_OmitType' and '_AnsibleTaggedStr'` |
| `list1 + 3` | `can only concatenate list (not "int") to list` |
| `d1 + d2` | `unsupported operand type(s) for +: '_AnsibleLazyTemplateDict' and ...` |
| `x + list1` | `can only concatenate str (not "_AnsibleLazyTemplateList") to str` |
| `null_var - x`, `list1 - 3` | same `unsupported operand type(s) for -:` shape |

krikri's messages mirror the STRUCTURE exactly (the str-concat vs
binary-op split included) but name operand types by their plain
Python names - `str`, not `_AnsibleTaggedStr`; `omit`, not
`_OmitType` - since ansible-core's tagged/lazy subclass names are
version-specific internals not worth pinning.

### What changed

- `expression_evaluator.cr`: `combine_plus` no longer has a lenient
  string-concat fallback - every non-concatenand pair raises
  `PlusMinusOperandError`; `combine_minus`'s old JSON-null else branch
  raises the same way. `resolve_plus_operand` gained a `strict:`
  flag (only `+`/`-` pass it; `~` and mult/div's operand fallback
  keep the lenient default) that (a) resolves bare `omit`/`none`
  operands to their real values so the combine sees the class real
  Ansible fails on, and (b) raises `'x' is undefined` for a
  genuinely-missing BARE-reference operand (gated on the same
  conservative `REGEX_BARE_VAR_REF` shape the `strict:` substitution
  path uses - a shape the evaluator can't resolve stays lenient
  rather than becoming a spurious failure). Also fixed while there:
  `combine_plus` lacked the `{Int64, Float64}` numeric case its `-`
  twin already had (int + float used to string-concat in the
  fallback; Crinja-first covered it, the fallback now matches too).
- NEW because of the Crinja probe result: the vendored Crinja is
  LENIENT on every one of these classes (it renders Undefined as "",
  None as its `"None"` repr, an omit operand as sentinel text, and
  even APPENDS for list + int) - so the Crinja-first `+` dispatch
  would succeed with garbage and never reach the now-strict fallback.
  The `+` dispatch therefore runs a strict operand-class gate BEFORE
  the Crinja attempt (`validate_plus_operands_strictly`): it re-runs
  the exact fallback resolution/combination once for validation, and
  only its own `PlusMinusOperandError` propagates - any other
  internal raise means "cannot validate conservatively" and leaves
  the Crinja-first attempt untouched, and `lookup(...)`/`query(...)`
  operands are skipped entirely (the same second-execution guard
  `Krikri.bracket_index_failure_message` applies). `-` needs no gate:
  Crinja already raises on every non-numeric `-` shape, so the strict
  fallback is always reached.
- New error class `PlusMinusOperandError < UndefinedVariableError`
  (variable_substitutor.cr) so every existing strict-undefined rescue
  site treats it as a task failure unchanged.
- 15 new specs in `expression_evaluator_spec.cr` (12 strict classes +
  3 valid-shape guards, including a `~`-stays-lenient scope-boundary
  lock). No existing spec asserted the old lenient behavior (the
  phase-2 pilot's own "no spec locks any of them" grep held).
- VERSION 0.9.1225 -> 0.9.1226 (+ README badge).

### Full-suite result

`crystal spec`: 5295 examples, 6 failures, 2 errors - exactly the
known-flaky nondeterministic cluster (`is_test_aliases_spec`'s
hardlink/tmp races, `x509_csr_info_spec`'s tmp-file race); both files
pass in isolation. Zero new failures. End-to-end probe of all 11
strict shapes against the rebuilt binary: every one now fails the
task with the matching message; `8080 + 2.5`, `'a' + 'b'`,
`list1 + list2`, `port + 10`, and `~` still render as before.
