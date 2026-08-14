# Crinja notes / architecture reference

Status: **no open tasks** (as of 2026-08-14). This file is kept as a compact
reference for anyone doing future Crinja/templating work. The extensive
per-round narrative that previously lived here has been trimmed; the history
lives in `git log`, `KNOWN_MISSING.md`, `ROLES_TESTED.md`, the personal memory
notes, and the fork's own `PATCHES.md`.

## The setup (facts, not history)

- Two independent Jinja2 evaluators coexist: a hand-rolled `{{ }}` evaluator
  (`ExpressionEvaluator`/`ConditionalEvaluator`/`ComparisonEvaluator`/
  `FilterEngine`, under `src/crystal_play/variable_substitutor/`) and the
  vendored **Crinja** shard, used for real `.j2` files and `{% %}`/`{# #}`
  block tags via `CrinjaRenderer`.
- Crinja is **forked** to `github: weirdbricks/crinja`, pinned by **tag** (never
  a branch) in `shard.yml` (currently `crystal-play-0.9.5`). `lib/crinja` is
  `.gitignore`d and re-fetched by `shards install` — **never edit it directly**;
  edit the fork's source, commit, tag, push, and repin.
- Every `crinja_*_ext.cr` monkey-patch was migrated into the fork's real source
  long ago (0.9.323). crystal-ansible carries **zero** Crinja patches.
  `jinja_filters.cr` still holds the genuinely **Ansible-specific** filters/
  tests that don't belong in a general-purpose Jinja2 engine (`to_datetime`,
  `bool`, `ternary`, `comment`, `password_hash`, `regex_search`, `flatten`,
  `shuffle`, the `version`/`match`/`search`/`failed`/`changed`/... tests, etc.).
  The fork's `PATCHES.md` is the authoritative patch/divergence manifest.

## Key decisions (why it is the way it is)

- **D1 — Never replace Crinja.** It is the only Jinja2 implementation in
  Crystal. Shelling out to Python reintroduces the exact dependency the project
  exists to remove; FFI to minijinja swaps one imperfect engine for another at
  the cost of a Rust toolchain and a hot-path boundary. Writing our own parser
  is already half-done and is itself the problem.
- **D2 — Maintain a fork (decided; don't re-open).** Upstream
  `straight-shoota/crinja` is in maintenance-only mode (~1 substantive commit
  a year), so the rebase burden is near zero, and a fork lets us carry fixes
  pinned by tag instead of monkey-patching a `branch: master` dependency.
  Upstreaming our fixes as PRs is **done-decided (not doing it)** — everything
  stays in the fork.
- **D3 — Converge on Crinja; the hand-rolled evaluator delegates to it.**
  Crinja's real recursive-descent parser gets precedence/parsing right by
  construction; the hand-rolled string-dispatch evaluator is where most
  templating bugs historically came from. The direction: the hand-rolled path
  tries Crinja first wherever possible and falls back to itself on any failure.
  Both gates were resolved in favor of convergence: with a source-keyed parse
  cache Crinja is 2-9x faster (measured), and the divergence gap is a long tail,
  not a chasm.

## Current state / deliberately-unconverged pieces

`ExpressionEvaluator`'s `#evaluate_expr` is fully converged (every dispatch
branch tries Crinja first). What remains hand-rolled is intentional:

- **`lookup(...)` bare-calls** — an Ansible-only feature (real Ansible's lookup
  *plugins*: `first_found`/`env`/`url`...). Crinja has no equivalent function,
  so it stays in `evaluate_lookup`. Not a gap.
- **`to_datetime` + Time arithmetic** — works. `jinja_filters.cr` registers
  `to_datetime` (returns a `Crinja::Value` wrapping a real `::Time`); the
  fork's `-` operator subtracts two `Time`s into `Crinja::TimeDelta`
  (`.days`/`.seconds`/`.total_seconds()`). os_hardening-style
  `( a | to_datetime - b | to_datetime ).days` renders through Crinja in one
  pass.
- **Trim markers** — expression-mode `{{- ... -}}` is handled correctly by the
  fork's lexer; no workaround remains. `lstrip_blocks` stays OFF because real
  ansible-core never enables it (so offline is correct, not a hack).
- **Known, accepted cosmetic divergence** — recursive-for + trim markers leave
  extraneous newlines vs. real jinja2 (rare in real roles; reworking the trim
  engine risks live-verified common-case output). Documented in the fork's spec
  suite with a KNOWN DIVERGENCE note.

## Working with it (bare minimum)

- Add/fix Crinja behavior: edit the fork clone (`~/git_work/crinja`), add a
  fork spec, commit, tag (`crystal-play-<n>`), push, repin `shard.yml`, `shards
  update`, run specs + `./build.sh`. Keep the fork's own spec suite (all green)
  green — it's the first line of defense.
- crystal-ansible's raw-Crinja rebase canary: `spec/unit/crinja_direct_spec.cr`
  tests the maintained registrations against `Crinja.new` directly — after any
  fork rebase it flags redundant (safe-to-delete) or regressed registrations.
- Bug-fix discipline: the same bug class (recursive re-templating, truthiness,
  etc.) has historically lived INDEPENDENTLY in both the hand-rolled evaluator
  and Crinja — when fixing one, audit the other. Convergence now funnels most
  cases through Crinja, but the hand-rolled fallback paths remain.
- The differential harness (`scripts/crinja_corpus/`) compares raw Crinja vs.
  real Python jinja2 on scraped corpus expressions. Python-as-oracle is for
  TESTING only, never a runtime engine.
