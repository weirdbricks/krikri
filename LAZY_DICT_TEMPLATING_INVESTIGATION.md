# Lazy dict-templating: investigation notes (2026-09-05)

**RESOLVED (same day, 0.9.740 / `crystal-play-0.9.24`)**: the
`PowerDNS.pdns` shape (problem A below) is fixed - but NOT via this
doc's section-6 sketch. The `each`/`raw_each` semantic flip was judged
too risky (the two-variable pairs form is load-bearing for shipped
roles); instead the two lossy paths got targeted key-yielding
special cases in the fork itself (`for` tag single-variable + `sort`
on a raw Hash). Fork commit `cde6938d`, tag `crystal-play-0.9.24`,
PATCHES.md section "crystal-play-0.9.24"; krikri side: Round 305 in
`KNOWN_MISSING.md`. Problem B below remains open, as does the
sketch's unexecuted filter-audit question for the remaining
`to_a`/`each` consumers (deliberately left reactive - see the fork's
PATCHES.md "Known remaining divergence" note). The rest of this doc
is kept as the root-cause record; section 6's sketch is historical.

Handoff notes for whoever picks up `KNOWN_MISSING.md`'s open gap
**"Ansible's lazy dict-templating is not replicated in general."** This
file records what was actually found, what was tried, why the attempt
didn't fully work, and a concrete design sketch for a real fix - so the
next session (possibly a more capable model, given the scope) doesn't
have to re-derive any of this.

This is investigation output, not a finished design doc: some of the
"recommended path forward" below is a sketch, not verified code.

---

## 1. The gap, precisely

Real Ansible's templar keeps a variable built from a `{{ }}` expression
as a genuine dict/list-like object all the way through the vars
pipeline (its private `_AnsibleLazyTemplateDict`). krikri's own `{{ }}`
substitution is string-based: the value coerces to a string, and a
later `{% for key, val in some_var %}` over it fails with "cannot
unpack multiple values of type Crinja::Value" unless the exact shape
has been special-cased.

**Only 3 roles have ever hit this, across every benchmark round to
date:**

| Role | Shape | Status |
|---|---|---|
| `jtyr.nsswitch` | `some_var: "{{ some_dict.update(other_dict) }}{{ some_dict }}"` then `{% for key, val in some_var.items() \| sort %}` | Fixed (0.9.697-0.9.700) |
| `jtyr.motd` | Same `.update()`-then-reread idiom, plus `motd_info: "{{ list_a + list_b }}"` (list concat of dicts needing recursive re-render) | Fixed (same round) |
| `PowerDNS.pdns` | `{% for backend in pdns_backends \| sort() %}` - a SINGLE loop variable over a dict | **Still open** |

A 4th role, `Oefenweb.bash`, hit an adjacent but DIFFERENT bug in this
same area (`Value#compare` had no `Crinja::Tuple` case, so sorting a
dict's `.items()` crashed) - already fixed in 0.9.645, not part of this
gap.

**On frequency**: `KNOWN_MISSING.md` cites "1 genuine occurrence in a
611-role corpus, ~0.16%" as supporting evidence this rewrite isn't
worth it. That figure is from a *different*, related frequency scan (a
type-coercion issue in comparisons - `robertdebock.java`/`buluma.java`'s
`java_version == 8`), not a dedicated scan of this specific
dict-templating/for-loop pattern. Nobody has run a wide-corpus scan
counting this exact shape. The honest count is the table above: 3
roles, ever, 2 fixed, 1 open.

---

## 2. Two separate problems living under one gap name

It's important to keep these apart - the existing writeup conflates
them somewhat:

**(A) Crinja-internal iteration/filter semantics for a Dictionary
value.** This is what `PowerDNS.pdns` actually hits. It's scoped to the
vendored `crinja` fork (`lib/crinja/`, `github: weirdbricks/crinja` in
`shard.yml`) and is what section 3-5 below is about. This turned out to
be **more tractable than first estimated** - see the design sketch.

**(B) krikri's own `{{ }}` substitution not preserving arbitrary
dict/list types through the vars pipeline in general.** This is the
deeper architectural problem - genuinely major, touches both
evaluators (the hand-rolled `variable_substitutor/` AND
`CrinjaRenderer`), and is what would be needed for *novel* shapes
beyond the ones already hardcoded (the `UPDATE_THEN_REREAD_RE` special
case, the list-concat recursive-rerender special case). This is NOT
what was investigated here, and the case for attempting it is exactly
as weak as `KNOWN_MISSING.md` already says.

**This investigation was entirely about (A).** Fixing (A) closes the
`PowerDNS.pdns` shape specifically; it does not touch (B) at all, and
a future genuinely-novel dict-templating shape could still hit (B).

---

## 3. Reproducing the `PowerDNS.pdns` failure directly

Minimal repro (a `.j2` template through the `template:` module, NOT the
`loop:` task keyword - those are two entirely separate code paths;
`loop:` goes through krikri's own hand-rolled evaluator and never
touches crinja at all):

```yaml
# vars:
#   pdns_backends: {bind: {a: 1}, sqlite: {b: 2}}

# templates/test.j2:
{% for backend in pdns_backends | sort() %}
backend={{ backend }}
{% endfor %}
```

Real Ansible renders `backend=bind` / `backend=sqlite` (the sorted
keys). krikri renders `backend=('bind', {'a': 1})` /
`backend=('sqlite', {'b': 2})` - `backend` is a 2-tuple, not a key
string, and the role's own later `backend | replace(...)` then crashes
with `Cast from Crinja::Tuple to (Crinja::SafeString | String) failed`.

---

## 4. Root cause, traced all the way through

1. `pdns_backends | sort()` calls into the `sort` filter -
   `lib/crinja/src/lib/filter/sort.cr`. Its body does `array =
   target.to_a` then sorts that array.
2. `Value#to_a` (`lib/crinja/src/runtime/value.cr:405`) - for anything
   that isn't already a raw `Array`, falls back to `each { |item| array
   << item }`.
3. `Value#each`/`#raw_each` (`lib/crinja/src/runtime/value.cr`,
   ~lines 205-248) - for a `Dictionary` (`alias Dictionary =
   Hash(Value, Value)`) raw value, UNCONDITIONALLY yields `(key,
   value)` tuples via `HashTupleIterator`, regardless of how many loop
   variables the caller actually wants.
4. So by the time `sort` returns, the dict has already become an
   `Array(Value)` of `Crinja::Tuple`s - the array literally no longer
   remembers it came from a dict.
5. The `for` tag (`lib/crinja/src/lib/tag/for.cr`) then iterates that
   array with `item_vars = ["backend"]` (one loop variable) and hands
   each `Tuple` straight to `backend`, instead of unpacking it or
   (correctly, per real Jinja2/Python) never having tupled it in the
   first place.

**Real Python/Jinja2 semantics**: iterating a bare dict yields just its
KEYS. `.items()` is the explicit opt-in for `(key, value)` pairs.
`sorted(some_dict)` returns the sorted KEYS. krikri's own vendored fork
inverts this by default for a Dictionary.

**Why it's this way at all**: before round 303 (0.9.738), the fork had
NO real `.items()` method on Hash values at all. krikri's own
`template_action_plugin.cr` used to work around that by textually
stripping `.items()` out of `{% for %}` tags via a regex
(`FOR_ITEMS_METHOD`, since removed) and relying on Crinja's bare `{%
for k, v in dict %}` already yielding `(key, value)` pairs - i.e. it
deliberately exploited this exact "wrong by Python standards" default
as its ONLY way to get two-variable dict iteration working at all. That
history is why `each`/`raw_each` defaults to tuples: krikri's own
templating layer depended on it. Round 303 added real `.items()`
support to the fork and removed the *textual* `.items()` stripping, but
never touched `each`/`raw_each`'s own default - so the old "always
tuples" behavior is still baked in underneath, and now conflicts with
plain Python-style single-variable iteration and with any filter
(`sort`, `dictsort`, `to_a`) that goes through the same path.

---

## 5. What I tried, and why it only half-worked

**Attempt**: patch the `for` tag itself (`lib/crinja/src/lib/tag/for.cr`,
in `interpret_output`) - right after `collection = env.evaluator.value(
collection_expr)`, if `item_vars.size == 1` and `collection.raw` is a
`Dictionary`, replace `collection` with `Value.new(dict.keys)` (just
the keys, as a real Array).

```crystal
if item_vars.size == 1 && (dict = collection.raw.as?(Dictionary))
  collection = Value.new(dict.keys)
end
```

**Result**: this compiles and correctly fixes a DIRECT `{% for backend
in pdns_backends %}` (no filter in between) - verified live, matches
real Ansible.

**But it does NOT fix the actual `PowerDNS.pdns` case**, because
`pdns_backends | sort()` runs BEFORE the `for` tag ever sees the
collection (see section 4, steps 1-4) - by the time the `for` tag's
`collection` variable is set, `collection_expr` already evaluates
through the `sort` filter, and `sort`'s own `to_a` has already
converted the dict into an `Array(Value)` of tuples. The `for` tag's
`collection.raw.as?(Dictionary)` check never matches, because
`collection.raw` is now an `Array`, not a `Dictionary`, by construction.
**This is the actual reason the real bug survives a `for`-tag-only
fix**: the type information ("this came from a dict") is lost one
layer earlier, inside `sort`.

I reverted this patch (see section 7 - it lives in a location that
can't be committed anyway). It's recorded here because it's a genuinely
useful PARTIAL step (see the design sketch, section 6, item 3) even
though it doesn't close the actual reported bug on its own.

---

## 6. Design sketch for a real fix (not implemented, not verified)

The fix needs to happen at the SHARED root (`each`/`raw_each`/`to_a`),
not just at the `for` tag, and needs to preserve the two behaviors
krikri already ships and has regression specs for:

1. **`some_var.items() | sort`** (real `.items()`, explicit) must keep
   yielding `(key, value)` tuples - this already works today via the
   round-303 `python_hash_methods.cr` addition and is unaffected by
   this plan.
2. **Bare `{% for key, val in some_var %}`** (TWO loop variables, no
   `.items()` at all) must keep yielding `(key, value)` pairs - this is
   the historical workaround krikri's own templates rely on (jtyr.motd:
   `{%- for key, value in item.items() %}` actually now uses real
   `.items()`, per round 303 - worth checking whether ANY currently-
   passing spec or live-verified role still needs the bare-two-var-no-
   items() form; if none do anymore, this compatibility shim might be
   safely retirable, which would simplify the fix a lot. Check
   `spec/unit/crinja_renderer_spec.cr` line ~594 and
   `spec/unit/expression_evaluator_spec.cr` first.)
3. **Bare `{% for key in some_var %}`** (ONE loop variable) and
   anything that goes through `each`/`to_a` without an explicit
   `.items()` (`sort`, `dictsort`, presumably `map`/`select`/membership
   tests/`length`/etc.) should see just the KEYS, matching real Python.

Sketch:

- Change `Value#raw_each`/`Value#each` (`lib/crinja/src/runtime/
  value.cr`) so a `Dictionary` raw value yields just its KEYS by
  default (matching Python's own `for k in dict:`), not `(key, value)`
  tuples. This is the actual semantic flip.
- If (and only if) item 2 above is still needed after checking specs:
  move the "two-variable loop over a dict yields pairs" convenience
  OUT of `each`/`raw_each` and INTO the `for` tag itself
  (`lib/crinja/src/lib/tag/for.cr`) - i.e. when `item_vars.size >= 2`
  AND the collection's raw type is a `Dictionary`, have the `for` tag
  explicitly zip `dict.to_a` (Crystal's own `Hash#to_a`, which
  naturally yields `{k, v}` tuples) instead of relying on `each`'s
  default. This isolates the workaround to exactly the one place that
  still needs it, rather than leaking it into every consumer of `each`.
- Update `dictsort` (`lib/crinja/src/lib/filter/sort.cr`) - it
  currently calls `target.to_a` and directly indexes `key1[0]`/`key1[1]`
  assuming tuples. Once `to_a`/`each` default to keys-only, `dictsort`
  needs to build its own `(key, value)` pairs explicitly (e.g.
  `target.raw.as(Dictionary).to_a`, using Crystal's `Hash#to_a`
  directly rather than going through `Value#to_a`).
- Audit every other builtin/filter in `lib/crinja/src/lib/filter/` and
  `lib/crinja/src/lib/function/` that calls `.each`/`.to_a`/`.raw_each`
  on a `Value` for hidden reliance on the current tuple-by-default
  behavior for dicts - `map`, `select`/`reject`, `selectattr`/
  `rejectattr`, `join`, `list()`, `length`, `unique`, `groupby`, `in`
  membership tests, and anything doing loop unpacking. This is the
  actual unknown-sized part of the work - a straightforward grep-and-
  read pass, but every hit needs a judgment call about whether it
  should now see keys or still needs explicit `.items()`.
- Run the crinja fork's OWN spec suite (`lib/crinja/spec/`, notably
  `spec/tags/for_spec.cr` and `spec/lib/filter_spec.cr`) FIRST, before
  ever touching krikri - it's a much faster regression signal than
  krikri's full suite and will catch upstream-semantic breaks directly.
- Then rebuild krikri, run the full `crystal spec` suite (currently
  2501 examples) and full `ameba` (446 files), and live-verify all 3
  known shapes end to end: `jtyr.nsswitch`, `jtyr.motd` (both must
  still render byte-identical to real Ansible - regression risk is
  real here, they're the two already-shipped shapes), and a
  `PowerDNS.pdns`-style repro (the actual role may or may not still be
  reachable on Galaxy - check `ROLES_TESTED.md` first; the minimal
  repro in section 3 above is a safe fallback).

**Unresolved question this sketch does NOT answer**: how many other
filters/functions in the fork implicitly depend on dict-iteration
yielding tuples. That's real, non-trivial audit work, not something to
estimate away - budget for it.

---

## 7. Release mechanics - `lib/crinja` is NOT a git checkout

**Important, easy to get wrong**: `lib/crinja/` (like everything under
`/lib/`, gitignored - see `.gitignore`) is plain `shards install`-
extracted source, not a git clone. It has no `.git` directory at all.
Editing files there is fine for local build-and-test iteration (the
build genuinely compiles from there), but:

- The edit is invisible to `git status` in krikri and will NOT be
  committed by any normal workflow.
- It vanishes the next time anyone runs `shards install`.
- **Do not `cd lib/crinja` and run `git` commands assuming it's an
  independent repo.** Git will walk up to the PARENT directory and find
  krikri's own `.git` instead, silently operating on krikri's actual
  repository. This bit me during this investigation: `git remote
  set-url origin ...` run from inside `lib/crinja` actually changed
  krikri's own `origin` remote to point at `weirdbricks/crinja`, and a
  subsequent `git fetch --tags` pulled ~10 stray crinja version tags
  into krikri's local repo. Caught immediately (nothing was ever
  pushed), `origin` was restored to `git@github.com:weirdbricks/
  krikri.git`, and the stray tags were deleted locally. `main` was
  never actually affected, but it's a sharp edge worth naming
  explicitly so the next person doesn't repeat it.

**The actual fix needs a fresh, real clone**: `git clone
git@github.com:weirdbricks/crinja.git` somewhere OUTSIDE this repo
tree, check out the currently-pinned tag (`crystal-play-0.9.23` - see
`shard.yml`), branch from there, make the changes from section 6, run
the fork's own specs, then:

1. Commit and tag a new version on the fork (e.g.
   `crystal-play-0.9.24`), push both to `weirdbricks/crinja`.
2. Bump `shard.yml`'s `crinja:` entry to the new tag.
3. Run `shards install` in krikri (updates `shard.lock` too).
4. Rebuild (`./build.sh`), run the full spec suite + `ameba`, live-
   verify per section 6's last bullet.
5. Bump `src/krikri/version.cr`, update `KNOWN_MISSING.md` (close the
   `PowerDNS.pdns` shape specifically; the general architectural gap
   (B) from section 2 stays open and documented as-is), update
   `README.md`'s version badge.
6. Commit `shard.yml`/`shard.lock`/the version bump/docs together in
   krikri; the fork's own commit+tag is a separate repo's history.

---

## 8. Summary for whoever picks this up

- The `PowerDNS.pdns` shape (problem A) is fixable without the full
  architectural rewrite (problem B) - it's a real, scoped, well-
  understood bug in the vendored crinja fork's Dictionary iteration
  defaults, not the "major undertaking touching both evaluators" the
  gap's framing implies for the general case.
- The blast radius is still real: `each`/`raw_each`/`to_a` are shared
  by many filters/functions, so the audit in section 6 is the actual
  unknown-sized work, not the core semantic change itself (which is a
  few lines).
- Two already-shipped, tested shapes (`jtyr.nsswitch`, `jtyr.motd`)
  MUST keep working exactly as they render today - they have live-host
  verification on record and pinned regression specs; treat any change
  to their rendered output as a regression, not a refinement.
- This requires a real release on a separate forked dependency
  (`weirdbricks/crinja`), not just a krikri-side commit - budget time
  for that cycle, and remember `lib/crinja` here is not where the
  permanent fix lives (section 7).
