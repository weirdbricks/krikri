# Crinja notes (round 21, 2026-08-13; strategy section updated 2026-08-13;
# step-1 harness built and run 2026-08-13, see "Step 1 results" below)

> **If you are a model picking this up cold, read "Step 1 results" and then
> "Strategy and next steps" at the bottom first** - they supersede the
> older, vaguer "Recommendation for a more serious pass" thinking and tell
> you what to actually do next and in what order. The bug sections in the
> middle are reference material for when you get there.

Working notes for whoever picks up a more serious pass at Crinja (the vendored
Jinja2-for-Crystal shard, `github: straight-shoota/crinja`, pinned to `branch:
master` in `shard.yml`). Not committed - purely a handoff document for other
models/sessions. Written after round 21 of the real-host benchmark workflow
(see `CLAUDE.md`), which for the first time exercised a real Ansible
**Collection** (`prometheus.prometheus`, specifically the `node_exporter`
role and its shared `_common` role) rather than a plain Galaxy role. That
role turned out to be an unusually deep stress-test of Crinja specifically,
surfacing more distinct Crinja bugs in one round than any prior round.

## Why this matters enough to write down

`lib/crinja` is `.gitignore`d (`/lib/` in `.gitignore`) - it's fetched fresh
by `shards install` every time, so **any direct edit to files under
`lib/crinja/` is silently lost** the next time someone runs `shards install`
(a fresh clone, CI, another dev's machine). This is not a hypothetical: it's
exactly what happened when I first tried debugging this - editing
`lib/crinja/src/...` directly to add print statements, then remembering
partway through that none of it would survive.

The established, working pattern in this codebase is to **monkey-patch
Crinja's own Crystal classes** from small `src/crystal_play/crinja_*_ext.cr`
files, each `require "crinja"` then `class Crinja::Whatever; ...; end` to
reopen and override/extend. This works because Crystal compiles the whole
program as one unit - reopening a class from a different file is completely
normal Crystal, no different from reopening it from the same file, as long
as both files get `require`d somewhere in the build. Existing examples,
worth reading before starting anything new:

- `src/crystal_play/crinja_trim_blocks_ext.cr` - reopens `Crinja::Renderer`,
  overrides `self.trim_text` entirely (a full method replacement, not just
  an addition)
- `src/crystal_play/crinja_truthy_ext.cr` - reopens `Crinja::Value`, fixes
  `#truthy?`
- `src/crystal_play/crinja_bool_ext.cr`, `crinja_hash_ext.cr`,
  `crinja_string_ext.cr` - smaller targeted fixes/additions
- `src/crystal_play/crinja_ternary_expr_ext.cr` - **new this round**, adds
  an entirely new AST node type + parser rule + evaluator visit (see below)
  - the most invasive patch of this kind so far, and proof the pattern
    scales to "add a missing language feature," not just "fix a
    misbehaving one"

These all get `require`d from `src/crystal_play/jinja_filters.cr` and
`src/crystal_play/variable_substitutor/crinja_renderer.cr` - any new
`crinja_*_ext.cr` file needs to be added to both `require` lists (or at
least one, transitively) to actually take effect.

## Bugs found and fixed this round

All of these were found via the SAME real symptom category: a role default
or task param written as real, valid Ansible-authored Jinja2 either threw a
`Crinja::TemplateSyntaxError`, or silently rendered wrong/`"undefined"`
instead of raising - meaning some of these went undetected for a while
before being noticed. **Recommend writing a regression spec for each
directly against Crinja's own `Crinja.new` / `env.from_string(...).render`
API** (bypassing this codebase's own `CrinjaRenderer` wrapper) so a future
`shards install` picking up a newer/older Crinja revision would immediately
flag if any of these got fixed upstream (redundant patch, safe to delete) or
newly broken (regression).

### 1. Trim marker (`-`) on an EXPRESSION tag, not just a block tag

`{{ expr -}}` / `{{- expr }}` (real, valid Jinja2 whitespace control,
usable anywhere - not just on `{% %}` block tags) mistokenizes. The
lexer's `check_for_end` (`lib/crinja/src/parser/template_lexer.cr`) handles
trim markers correctly at the tokenizer level in general, but somewhere in
the expression-parsing path a `-` immediately before `}}` gets tokenized as
a literal MINUS **operator** instead of a trim marker, corrupting the whole
expression: `'x' -}}` parses as `'x' - <undefined>`, which then renders as
the literal text `"undefined"` instead of `"x"`. Confirmed via:

```
"{{ 'x' -}}"   => "undefined"   (wrong - should be "x")
"{% if true -%}YES{% endif %}"  => "YES"  (correct - block-tag form is fine)
```

**Not fixed at the Crinja/lexer level** - worked around in this codebase by
preprocessing the template TEXT before handing it to Crinja at all
(`CrinjaRenderer#normalize_expression_trim_markers`,
`src/crystal_play/variable_substitutor/crinja_renderer.cr`): scans for
`{{...}}` spans, detects a leading/trailing `-`, and physically removes
both the marker character and the adjacent template-source whitespace
before parsing - i.e. reimplements the *effect* of the trim marker via
string surgery rather than fixing the tokenizer. This works and is tested,
but it's a workaround, not a real fix - a genuine fix belongs in
`lib/crinja/src/parser/template_lexer.cr`'s expression-mode tokenizing (I
did not find the exact line; the block-tag-mode handling in
`check_for_end` looks structurally correct and complete, so the bug is
likely in a SEPARATE lexer mode entered specifically while inside a
`{{ }}` expression, not shared with the block-tag scanner at all).

A parallel, narrower version of the same underlying gap exists in this
codebase's OWN hand-rolled evaluator too (not Crinja) - see
`VariableSubstitutor#expand_mustache_spans`
(`src/crystal_play/variable_substitutor.cr`), which is what actually
handles a `{{ }}`-only span (no `{% %}` anywhere in the surrounding text)
without ever invoking Crinja at all. That one's fixed by just stripping the
marker character from the extracted inner expression - simpler, since this
evaluator was never doing real whitespace-control in the first place.

### 2. Jinja2's native inline ternary (`X if COND else Y`) - entirely missing

Not "wrong" - completely absent from the grammar. Two different failure
shapes depending on parenthesization:

```
"{{ 'a' if true else 'b' }}"     => TemplateSyntaxError: expression was
                                     not fully parsed: IDENTIFIER:"if"
"{{ ('a' if true else 'b') }}"   => TemplateSyntaxError: Expected
                                     RIGHT_PAREN, got IDENTIFIER
```

This is real, common Ansible-role-author Jinja2 (distinct from Ansible's
OWN `| ternary(true_val, false_val)` FILTER, which this codebase's
`jinja_filters.cr` already implements separately and correctly - that one
never touches Crinja's parser at all, it's just a filter function). The
inline form is standard Jinja2 syntax straight from the upstream language
spec, not an Ansible extension, so its total absence is surprising for an
otherwise fairly complete Jinja2 implementation.

**Fixed** via `src/crystal_play/crinja_ternary_expr_ext.cr`: reopens
`Crinja::Parser::ExpressionParser` to override `#parse_expression` (adding
a `parse_condexpr` layer above the existing `parse_logical_or` chain,
mirroring real Jinja2's own `parser.py#parse_condexpr` - right-associative,
optional `else` defaulting to Undefined), reopens `Crinja::AST` to add a
new `CondExpr` node via the existing `expression_node` macro, and reopens
`Crinja::Evaluator` to add a `visit CondExpr do ... end`. This is a
complete, from-scratch grammar addition, not a one-line fix - review it
carefully if picking this file back up; I did not attempt equivalent
support for a ternary appearing as a `{% set %}` target or inside other
Crinja tag contexts beyond plain `{{ }}` output, though the parser-level
fix should apply universally since `parse_expression` is the single shared
entry point every context uses.

### 3. `namespace()` builtin - NOT fixed, found but not investigated

The actual remaining blocker that ended the round. Real Jinja2's
`namespace()` function creates a mutable-attribute object that - unlike a
normal `{% set %}` variable - is NOT re-scoped fresh on each `{% for %}`
loop iteration, the standard way to accumulate/mutate state across a loop
in Jinja2 (since plain `{% set %}` inside a `{% for %}` body is invisible
outside that single iteration - a deliberate Jinja2 scoping rule people
constantly get bitten by, which `namespace()` exists specifically to work
around). Exact failing real-world template
(`prometheus.prometheus`'s own `roles/_common/templates/node_exporter.service.j2`,
though this pattern is copy-pasted near-verbatim across most of that
collection's other exporter service templates too - grep the collection
for `namespace(` if picking roles for a future round):

```jinja
{% set ns = namespace(protect_home = 'yes') %}
{% for m in ansible_facts['mounts'] if m.mount.startswith('/home') %}
{%   set ns.protect_home = 'read-only' %}
{% endfor %}
ProtectHome={{ ns.protect_home }}
```

Failure: `Failed to render template:  is undefined` pointing at the
`namespace(protect_home = 'yes')` call itself - so at minimum the
`namespace` builtin function isn't registered at all (unlike the ternary
case above, which had SOME grammar handling that then errored; this looks
like a plain "unknown function/undefined identifier" failure, worth
confirming by testing `{{ namespace() }}` in isolation before assuming the
full scope of what's missing - there may ALSO be a separate gap in
`{% set ns.attr = ... %}` attribute-assignment syntax even once `namespace()`
itself exists, since that's arguably a second distinct feature - real
Jinja2's normal `{% set %}` only ever supports a bare name target, not a
dotted attribute path, and namespace objects are specifically the one
exception to that rule).

Not investigated further this round - stopped here per user direction to
consolidate notes instead of continuing indefinitely deeper into Crinja.

### 4. Regex `match`/`search` Jinja tests - NOT a Crinja bug (documented for contrast)

Not actually a Crinja issue, but worth noting since it was found in the
same investigation and could be mistaken for one: `select('match', ...)`/
`reject('match', ...)` (the FILTER forms) were entirely unimplemented in
THIS codebase's own hand-rolled `FilterEngine`
(`src/crystal_play/variable_substitutor/filter_engine.cr`) - `is match(...)`
as a bare Jinja TEST already worked correctly (confirmed directly), it was
only the filter-form dispatch that was missing, plus a separate Python-
string-literal-escaping gap (`'\\d'` needing `\\` -> `\` unescaping, which
neither evaluator was doing) compounding it. Both fixed this round in
`filter_engine.cr`, not Crinja. Included here only so it doesn't get
mistakenly re-attributed to Crinja by someone skimming git log later.

## Prior known Crinja gaps (from git history, not re-verified this round)

Found via `git log`/`KNOWN_MISSING.md` search for "Crinja" - listed here for
context on what's ALREADY been fixed vs. what's a known, deliberately
unfixed cosmetic gap, so a future audit doesn't waste time rediscovering
either:

- **`.split(...)` with no arguments** - fixed (Crinja had zero support for
  Python's whitespace-run split at all)
- **`Value#truthy?`** - fixed via `crinja_truthy_ext.cr` (empty
  string/array/hash were all wrongly truthy, unlike real Python `bool()`)
- **Bool-to-string finalization** (`{{ some_bool }}` rendering Crystal's
  lowercase `true`/`false` instead of Python-style `True`/`False`) - fixed
  via `crinja_bool_ext.cr`
- **`-%}`/`{%-` explicit whitespace-control markers under-trim by one blank
  line** across a skipped `{% if false %}...{% endif -%}` immediately
  followed by another `{%- if %}` block - confirmed via direct comparison
  against real Python `jinja2.Environment(trim_blocks=True)`, **deliberately
  left unfixed** (purely cosmetic, a stray blank line in a config an INI
  parser ignores; the comment at `KNOWN_MISSING.md`'s own "Narrow,
  deliberately-scoped items" section explicitly says it needs
  `lib/crinja/src/parser/template_lexer.cr`'s own `check_for_end`/
  `trim_left`/`trim_right` lexer-level trim-distance tracking, i.e. the
  SAME general area as bug #1 above - possibly worth fixing both together
  if someone takes on a real lexer-level pass, since they may share a root
  cause)
- `lstrip_blocks` is forced OFF in this codebase's own Crinja config
  (`CrinjaRenderer`'s `env.config.lstrip_blocks = false`) - search
  `crinja_renderer.cr` for why; IIRC another under-trimming mismatch
  against real Jinja2 that was easier to work around by disabling the
  feature than fixing

## Strategy and next steps

This section replaces the earlier, looser "worth considering" list. It was
written after reviewing all 21 rounds of `KNOWN_MISSING.md` + `git log` for
templating bugs, the six `crinja_*_ext.cr` patches, the dual-evaluator
dispatch in `variable_substitutor.cr`, and upstream Crinja itself. Nothing
below has been executed yet.

### Decision 1: do NOT replace Crinja

Answered directly, so nobody re-opens it every round:

- **There is no second Jinja2 implementation in Crystal.** Crinja is the
  only one. This is not a shortlist of one out of laziness; it genuinely
  has no competitor in-language.
- **Shelling out to Python `jinja2`** reintroduces the exact dependency
  this project exists to remove, plus a subprocess per render. Rejected as
  a runtime engine - but it is exactly the right tool as a *test oracle*,
  see step 1 below.
- **FFI to minijinja** (Rust, written by Jinja2's own author, has a
  `minijinja-cabi` C ABI) is the only technically serious alternative and
  would likely be the highest-fidelity engine available. Still rejected:
  it adds a Rust toolchain to `build.sh`, puts an FFI boundary in the
  hottest path in the program, and would require rewriting the several
  thousand lines of this codebase that are shaped around `Crinja::Value`
  and Crinja's env/filter/test registries. That is a large rewrite to swap
  one imperfect engine for another imperfect engine. Revisit only if step 1
  below shows Crinja's gap to real Jinja2 is enormous rather than a long
  tail.
- **Writing our own parser** is already half-done and is the actual
  problem - see Decision 3.

### Decision 2: yes, fork Crinja - the cost is near zero

Upstream activity, measured 2026-08-13 (re-check before acting, but this
was the state):

- Upstream HEAD `118af0d` (2026-07-21). We are pinned at `4688cc7`
  (v0.9.0, 2026-01-20) via `shard.lock`.
- **Five commits in those seven months. Four are Renovate CI bumps.** One
  substantive fix (`3075d78`, resolve() precedence).
- It is *not* abandoned - outside-contributor PRs do get merged (#94, #102,
  #85, #86) - but it is in maintenance-only mode, roughly one substantive
  commit a year. **A fork's rebase burden here is approximately zero.**

Reasons to fork, strongest first:

1. **`shard.yml` currently says `crinja: branch: master`.** `shard.lock`
   saves us today, but any `shards update` silently pulls whatever upstream
   master happens to be - into a dependency we have patched six ways from
   the outside via method *overrides*, which would break silently (not
   loudly) on an upstream internal refactor. This alone justifies pointing
   at a fork we control, pinned to a **tag or SHA, never a branch**.
2. **Two known bugs are structurally unreachable by monkey-patching.**
   Bug #1 (expression-mode trim markers) is currently "fixed" by string
   surgery on the template source before Crinja ever parses it - that will
   misfire on a `-` inside a string literal or any other `-}}`-lookalike in
   user data. The `lstrip_blocks` gap was "fixed" by turning the feature
   off. Both need real lexer edits.
3. Patches become greppable, readable and debuggable in the file they
   belong to, instead of being action-at-a-distance class reopenings that
   a new contributor has to already know to look for.

Note the monkey-patch pattern is *not* wrong - `crinja_ternary_expr_ext.cr`
proves it scales even to adding a grammar rule. It is simply the wrong
default once the patch count passes ~6 and some fixes need the lexer.

### Decision 3: the fork is not the biggest lever - the dual evaluator is

The most important finding from reviewing the history: **Crinja is not
where most templating bugs come from.** Across 21 rounds Crinja accounts
for roughly 8-10 findings. The hand-rolled path (`ExpressionEvaluator` /
`ConditionalEvaluator` / `ComparisonEvaluator` / `FilterEngine`) accounts
for several times that, and they are worse in kind:

- `*`, `/`, `//` arithmetic **entirely missing** (round 12)
- `not a or b` parsed as `not (a or b)` (round 15) - and this doc's own
  bug #2 notes Crinja gets that right *by construction*, because it has a
  real parser
- `in`/`not in` split by a naive string scan, broken by a literal
  containing `"in"` (round 17)
- bare numeric literals never recognised standalone (round 12)
- recursive re-templating: **twelve independent buggy copies** across
  rounds 2-4
- empty-list/dict truthiness: fixed once centrally in Crinja, then found
  *again* separately in `ConditionalEvaluator` (0.9.249)

That is the signature of a string-manipulation evaluator versus a real
recursive-descent parser. Crinja's weaknesses are missing *features* -
bounded, enumerable, fixable once. The hand-rolled evaluator's weakness is
that it is not a parser, which is unbounded. And every templating fix
currently costs double, because it must be found and fixed in two unrelated
implementations - `CLAUDE.md`'s opening section already warns about this,
i.e. it is a known chronic tax, not a new observation.

**Direction (not yet a commitment): converge on Crinja as the single
evaluator and retire the hand-rolled one.** Two things gate it:

- *Performance.* `substitute` runs 2-4x per task per host, and Crinja
  re-parses on every `from_string` - its `template_cache` only covers
  loader-based templates, not string ones. Fixable in the fork with a
  source-keyed parse cache. The `includes?("{{")` early exit in
  `VarSubstitutor#substitute`, which is where the real savings already are,
  is unaffected either way. **Measure before committing; do not assume it
  is fatal, and do not assume it is free.**
- *Unknown gap size.* If step 1 below turns up ~5 divergence classes,
  full convergence is right. If it turns up ~50, the pragmatic answer
  changes to: fork, fix aggressively, keep both paths, but make the
  hand-rolled path **delegate to Crinja for anything more complex than a
  bare variable lookup**. Let the harness decide this - do not pre-commit.

### Step 1 results (2026-08-13)

Step 1 (differential harness) is built and has been run once. Lives at
`scripts/crinja_corpus/` (see its own `README.md` for how to regenerate -
its output files are gitignored-by-convention, not committed, since the
corpus depends on scratch trees that get destroyed between rounds).
Corpus: 1476 files across `testing/roles` + `~/scratch/round{2,3,4,5,6,7,
8,9,18,19,20,21}_bench` -> 3666 distinct expressions (`{{ }}` output spans
and `{% if %}`/`{% elif %}` conditions). Each rendered standalone (no
context vars bound) through real Python jinja2 3.1.6 and through raw
Crinja (`Crinja.new`, this codebase's `crinja_*_ext.cr` patches loaded,
`CrinjaRenderer`'s trim-marker-workaround NOT applied) and diffed.

**Sizing verdict for Decision 3: the gap is a long tail, not a chasm.**
67 high-confidence, closed-form divergences out of 3666 (~1.8%) - supports
"fork, fix aggressively" over "the gap is enormous, don't bother
converging." The other ~1489 "both sides error" cases were sampled and are
overwhelmingly expected noise (Ansible-only filters like `ternary`/
`regex_replace`/`password_hash` that neither raw Crinja nor raw Python
jinja2 know about - this codebase's `jinja_filters.cr` registers those
itself, outside what this harness exercises - plus undefined-variable
errors under two different exception class names).

New bugs found this way, not previously known, ranked by how many corpus
hits they explain (each is one root cause, not one bug per line):

1. **`or`/`and` return a stringified bool instead of the actual operand
   value** - `'' or 'fallback'` renders `"True"` in Crinja, not
   `"fallback"`. Real Jinja2 (and Python) short-circuit `or`/`and` return
   whichever *operand* won, not a boolean - this is the single most
   Ansible-idiomatic defaulting pattern (`{{ x or 'default' }}`) and it's
   broken. Note round 19 found this exact bug class (0.9.289-0.9.290) in
   this codebase's OWN hand-rolled evaluator - this is an INDEPENDENT copy
   of it inside Crinja itself, not the same bug re-surfacing.
2. **`X in [list literal]`** and **`'literal' in identifier`** both fail to
   parse (`TemplateSyntaxError`) when appearing as an `{% if %}` condition
   - 8 of the 11 bucket-A hits. `identifier in identifier` and `identifier
   in 'literal'` were not observed to fail, so the gap looks scoped to the
   `in` operator's right-hand precedence when the RHS is a bracket/paren
   literal specifically, not `in` generally.
3. **`not X in Y`** raises a raw `Exception: unreachable: invalid
   operator` - not even a clean `TemplateSyntaxError`, an internal
   assertion failure. Likely the same root cause as #2 (a `not`+`in`
   precedence interaction), worth investigating together.
4. **`.first` / `.list` / `.join(...)` filters raise `TypeError` on
   Undefined input** instead of the lenient empty-result real Jinja2 gives
   (`first` -> `''`, `list` -> `[]`, `join` -> `''`). Extremely common
   shape: a role's `defaults/main.yml` sets a list var, a template does
   `{{ that_var | join(',') }}`, and if the var is ever legitimately unset
   (conditional default chain, `ansible_parent_role_*` vars not being
   inherited, etc.) real Ansible silently renders empty where
   crystal-ansible would crash the whole render.
5. **`unique` filter not registered at all** in Crinja (2 hits, but
   `unique` is a common `| map(...) | unique | list` pipeline tail -
   likely undercounted since it only shows up when everything upstream in
   the pipeline also happens to succeed on Undefined input, which #4 often
   prevents).
6. **Nested/chained inline ternary** (`a if b else c if d else e`) fails
   to parse - `crinja_ternary_expr_ext.cr`'s new `parse_condexpr` layer
   handles one level but not the right-associative chain. Also: ternary
   combined with `in` in the same expression fails distinctly (bucket A's
   last two entries) - worth checking whether `parse_condexpr`'s
   precedence relative to `in` is the same root cause as #2/#3.
7. **Dict literal `.get(key, default)` method call** unsupported -
   `Exception: not implemented for Crinja::AST::DictLiteral`.
8. **Chained Python-style string methods** (`' '.join(x).split()`) fail -
   `Exception: not implemented for Crinja::AST::StringLiteral` - looks like
   Crinja's method-call-on-literal handling doesn't compose when the
   receiver is itself the result of a prior method call rather than a bare
   literal.
9. Two low-priority/cosmetic items, not worth chasing: `select`/`reject`
   without a trailing `| list` stringify as an actual list (`[]`) in
   Crinja vs. a generator repr in real Python/Jinja2 (real Jinja2 also
   never resolves the generator without `| list`, so arguably Crinja's
   behavior is more *useful*, just non-conforming); and Jinja2's `is
   iterable` test returns `True` for Undefined specifically because
   Python's `Undefined.__iter__` exists as a method even though calling it
   raises (a CPython `Undefined`-class quirk, not a spec behavior worth
   matching).

Full detail (all 67 rows with exact expressions and both sides' raw
output/error text) is in the generated, not-committed
`scripts/crinja_corpus/divergence_report.md` - regenerate via that
directory's `README.md` before relying on line numbers here, this section
is a summary taken from one run.

Update 2026-08-13, same session: **#1, #2, #3, #4, and #5 above are now
fixed**, via new `crinja_*_ext.cr` patches (the fork wasn't needed for
any of these - all monkey-patchable):

- `src/crystal_play/crinja_logic_ext.cr` - #1 (`and`/`or` return the
  actual operand, not a stringified bool). Two-method override
  (`Operator::And#value`, `Operator::Or#value`).
- `src/crystal_play/crinja_in_operator_ext.cr` - #2 and #3 (`in`/`not
  in` were entirely absent from the grammar - confirmed by direct test,
  `{% if 'a' in ['a','b'] %}` raised `TemplateSyntaxError` regardless of
  what was on either side of `in`, not just the list-literal-RHS shape
  originally guessed from the corpus sample). Adds a new
  `Operator::In`/`Operator::NotIn` pair plus three parser method
  overrides: `parse_less_greater` (new infix `in`/`not in` grammar rule),
  `parse_equal_not` (removes `NOT` from that level's own comparator set -
  it was wrongly treating bare `not` as a binary comparison operator,
  which is what actually produced the original "unreachable: invalid
  operator" crash for `"enabled" not in options`), and
  `parse_unary_expression` (so prefix `not X in Y` parses as `not (X in
  Y)`, matching real Jinja2/Python precedence, instead of `(not X) in
  Y`). The most invasive of this round's patches - three separate
  precedence-level interactions, not a single clean insertion point.
- `src/crystal_play/crinja_undefined_filter_ext.cr` - #4 (`first`/`list`/
  `join` no longer raise on an Undefined target, matching real Jinja2's
  `soft_str()`-mediated leniency; extended the same fix to `trim`/
  `replace`, which turned out to have the identical bug once the harness
  was re-run) and #5 (`unique(case_sensitive=false, attribute=none)`
  added from scratch, first-occurrence order).

All three files wired into both require chains (`jinja_filters.cr` and
`variable_substitutor/crinja_renderer.cr`) per this doc's own "monkey-
patch pattern" section above. Verified via: (a) direct hand-written
render assertions for every fixed shape, (b) re-running the step-1
harness - bucket A 11 -> 2, B 45 -> 6, C 9 -> 6 (67 -> 16 total
actionable divergences), (c) full `crystal spec` (1050 examples, 0
failures) for regressions, (d) `./build.sh` clean. Bumped to 0.9.314
(three fixes/commits' worth of behavior change in one bump - see this
doc's own note on why: found together in one investigation).

**Not fixed, left for a future pass** - the remaining 16 harness hits,
each individually rarer than #1-#5 and/or needing deeper parser surgery:

- **#6 (nested/chained ternary)** and **dict `.get(key, default)`**
  (`{'i386': '386', ...}.get(my_arch, my_arch)`) - both still raise;
  neither attempted this session.
- **New, found only after fixing #2/#3**: an unparenthesized filter call
  immediately followed by `in` swallows `in` as a bare filter argument
  instead of stopping (`x | string in ['a','b']` fails synthesizing
  `TemplateSyntaxError: Expected RIGHT_BRACKET, got COMMA` - `parse_call_
  expression`'s no-parens `end_tokens` set, expression_parser.cr:262,
  doesn't include `Kind::IDENTIFIER`, so a bareword like `in` right after
  a no-parens filter name gets parsed as that filter's own unparenthesized
  argument). Rare in practice (needs a no-parens filter call directly
  followed by `in`), not attempted this session.
- Chained Python-string methods (`' '.join(x).split()`), `match` test
  still missing (only the filter-form `select('match', ...)`/
  `reject('match', ...)` was fixed, and only in this codebase's OWN
  `FilterEngine`, not Crinja - see bug #4 in the "Bugs found and fixed
  this round" section above), `split` filter (Ansible's method-call
  `.split()` works via a different path already; the FILTER form
  `| map('split')` still isn't registered), `sum(..., start=[])` with an
  array/list start value (currently assumes numeric).
- Bucket C's 2 low-priority items from step-1 results (`is iterable` on
  Undefined, select/reject-without-`| list` stringifying as `[]` vs. a
  Python generator repr) - explicitly not worth chasing, see original
  reasoning above.

### The plan, in order

1. **Build a differential test harness. Do this first. DONE 2026-08-13** -
   see "Step 1 results" above; harness lives at `scripts/crinja_corpus/`.
   (Original framing, kept for context: scrape every
   `{{ }}` / `{% %}` span out of the roles benchmarked across all 21 rounds
   (plus the vendored roles under `testing/`, and any surviving
   `~/scratch/round*_bench/` trees) into a corpus file, then render each
   through both Crinja and real Python `jinja2.Environment` and diff the
   output. This is the enabling tool for everything else: it finds Crinja
   gaps in minutes rather than one expensive real-host round at a time
   (most of a benchmark round's wall-clock goes to provisioning, SSH and
   downloads, not template rendering). Python-as-oracle is correct *here*
   even though it is rejected as a runtime engine. Expected output: a
   ranked list of divergence classes, which then sizes Decision 3.)
2. **Fork Crinja.** Repoint `shard.yml` at the fork, **pinned to a tag or
   SHA, not a branch**. Do not big-bang port the six `crinja_*_ext.cr`
   patches - migrate each into the real source file the next time you need
   to touch it. Keep a `PATCHES.md` in the fork listing every divergence
   from upstream, so a future rebase is mechanical.
3. **Upstream the clean, non-Ansible-specific fixes** as real PRs to
   `straight-shoota/crinja`, regardless of what else happens - the log
   shows outside PRs do get merged. Best candidates: the inline ternary
   (`crinja_ternary_expr_ext.cr`), `Value#truthy?` (a genuine
   Python-semantics bug, not a preference), and `.split()` with no
   arguments. Anything upstream accepts is a patch we stop maintaining.
4. **Fix `namespace()`** in the fork, where it belongs. Remember it is
   likely *two* features: the `namespace()` runtime object, and the
   `{% set ns.attr = ... %}` dotted-target parser rule (see bug #3 above).
   Confirm with `{{ namespace() }}` in isolation before scoping.
5. **Then, and only then**, start incrementally routing hand-rolled paths
   through Crinja, one construct at a time, with the step-1 harness as the
   regression gate. This is the multi-week item. Do not start it before
   steps 1 and 2 exist - without the harness there is no way to tell a
   convergence regression from a pre-existing bug.

Also worth doing opportunistically, per this doc's own earlier note: write
each fixed Crinja bug up as a regression spec **against Crinja's own
`Crinja.new` / `env.from_string(...).render` API**, bypassing
`CrinjaRenderer`. Those specs are what tell you, after a fork rebase or a
`shards update`, whether a patch became redundant (upstream fixed it -
delete ours) or newly broken.
