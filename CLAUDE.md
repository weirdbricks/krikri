# CLAUDE.md

Guidance for Claude Code working in this repo. See the parent
`git_work/CLAUDE.md` for the cross-repo Dirless-workspace picture (this
repo is a standalone shard, not part of that platform).

## What this is

`krikri-playbook` (binary name `krikri-playbook`) is a from-scratch
reimplementation of `ansible-playbook` in Crystal: parses real Ansible
playbooks/roles/inventories and executes them, aiming for full
behavioral parity with real `ansible-core` - not just "the common
cases work." Two independent Jinja2/expression evaluators exist side
by side: a hand-rolled `{{ }}` evaluator (`ExpressionEvaluator`/
`ConditionalEvaluator`/`ComparisonEvaluator`/`FilterEngine`, under
`src/krikri/variable_substitutor/`) for plain task-param
substitution, and the vendored `Crinja` shard (`CrinjaRenderer`,
`TemplateActionPlugin`) for real `.j2` template files and `{%`/`{#`
block-tag rendering. They do **not** share implementation - the same
bug class (most often "recursive re-templating": a variable whose own
value is itself unrendered Jinja) gets found and fixed independently in
each, repeatedly. When fixing a templating bug, check both.

Each Ansible module is its own tiny compiled binary under `plugins/`,
uploaded to and executed on the target host (or run locally for
`ansible_connection=local`). `src/krikri/plugin_manager.cr`
handles upload/dispatch; `src/krikri/task_batcher.cr` groups
sequential tasks into one SSH round trip where safe.

## Build & test

```bash
./build.sh                          # builds bin/krikri-playbook + all bin/plugins/* (mtime-skip, safe to always run)
./build.sh --release                # only near the end of a work session - slow, not needed for correctness iteration
crystal spec                        # full suite
crystal spec spec/unit/foo_spec.cr  # one file - NOTE: some files fail in isolation (a pre-existing
                                     #   require-ordering artifact, not a real regression) - always
                                     #   confirm any single-file failure against the full `crystal spec` run
crystal spec spec/foo_spec.cr:42    # one example
ameba                               # lint
```

**Always run `./build.sh`**, never a bare `crystal build krikri-playbook.cr` alone, before trusting a
"still broken" result against a real host - plugin binaries compile separately from the main
executable and a manual build of just one leaves the other stale.

**Adding a new plugin** (e.g. a new module) needs registering in *three* places, easy to
miss one:
1. `plugins/<name>.cr` - the plugin itself (see any existing one for the `BasePlugin` pattern).
2. `src/krikri/playbook_parser.cr`'s `AVAILABLE_PLUGINS` array - module-name dispatch.
3. `build.sh`'s `PLUGINS` array - or `./build.sh` silently never rebuilds it. (This list was
   already found out of sync once - `apt_key` had no entry despite a real compiled binary - so
   don't assume it's currently complete without checking.)

## Version bumping

`src/krikri/version.cr`'s `VERSION` gets bumped with every commit that changes engine/plugin
behavior (not doc-only commits). One bump per logical fix or tightly-related group of fixes found in
the same investigation - not one per file touched.

## The real-host benchmark-round workflow

This is the primary way bugs get found - unit specs alone (900+) have never been enough; every real
round against a production Ansible role finds more. Read `KNOWN_MISSING.md`'s own intro before
starting a round.

Rounds are driven by **`krikri-role-tester`** (sibling repo,
`../krikri-role-tester`), a Crystal app that replaced the old shell drivers
(`testing/kata/run_role.sh`, `run_batch.sh`, and the various
`~/scratch/bench/run_role*.sh` scripts). Read its own `README.md` first - it
covers the queue-file format, the scheduler model, results layout, and both
backends in detail. The summary below is only what's specific to using it
from this repo.

1. **Check `ROLES_TESTED.md` first** for a role shortlist - avoids re-discovering Galaxy-404s
   (`geerlingguy.mongodb`/`.consul`/`.golang` don't exist anymore) or re-verifying already-clean
   roles as if new (unless deliberately re-checking after something made a host suspect).

2. **Batch phase:** build a queue file (one role per line, optional `kata`/`atlantic` hint) from
   the `ROLES_TESTED.md` shortlist, then run it:

       bin/krikri-role-tester run roles.txt \
         --kata-hosts 8 --atlantic-hosts 8 \
         --results-dir ~/scratch/krt-results --round-start 1000

   The tool runs both backends' worker pools concurrently (up to 4 pairs each), provisions a
   fresh pair per role, runs cold + warm on both engines, and normalizes PLAY RECAP counters into
   `SUMMARY|` lines under `<results-dir>/<round>_<backend>_<safe-role>/`. It also handles
   idempotency (each phase already runs the role twice) and the known plugin-upload UNREACHABLE
   race (same-host retry, up to 3, no reboot dance) itself - see its README's "Known divergences"
   section. Do **not** make engine code changes during this phase.
   - Any divergence still needs a minimal repro confirmed against real `ansible-playbook` (not
     assumed) before treating it as a krikri-playbook bug - plenty of "bugs" turn out to be broken
     upstream repos, missing Galaxy roles, or role-side gaps (e.g. `php-mysql`'s own repo ships no
     `vars/Debian.yml` at all) that affect real Ansible identically.

3. **Triage:** run `bin/krikri-role-tester report ~/scratch/krt-results --round-start 1000
   --round-end <N>` once the batch finishes, then dedupe the collected divergences - if two or
   more roles hit the same root cause, that's one fix to make, not two.

4. **Fix phase (serial):** apply fixes one at a time against the unit specs (concurrent edits to
   the same evaluator/plugin code aren't safe to parallelize even though the discovery phase is).
   Add a regression spec where practically possible (some things - real dpkg/apt mutation, real
   crontab mutation, real pip installs - have no spec at all by design; verify those live instead
   and say so in the commit message). Bump `VERSION` per logical fix or tightly-related group of
   fixes, run the full `crystal spec` suite, and `./build.sh`.

5. **Confirm phase:** re-run *only* the roles that diverged, via a fresh queue file against the
   rebuilt binary, before considering any fix done.

6. Update `KNOWN_MISSING.md` (the running per-round narrative) and `ROLES_TESTED.md` (the
   current-status table) together in one commit, covering the whole batch at once rather than
   per-pair; bump `README.md`'s version badge too.
   **Every role tested gets its own row in `ROLES_TESTED.md`'s table** (one role per row,
   not bundled into a shared "role / role / role" line even when several fail the same
   way) **and that row must include its cold/warm timing for both engines** - not just
   roles picked for a dedicated benchmark comparison. This is the only place per-role
   timings live (see `ROLES_TESTED.md`'s own note at the top). Older rows predating this
   convention (bundled entries, missing timings) are left as-is, not backfilled.

7. If a run was SIGKILLed, `bin/krikri-role-tester sweep ~/scratch/krt-results` finds rounds
   whose `run.log` never reached `DONE` and tears down their leftover terraform state directly.

## Local Kata test hosts (a backend of krikri-role-tester)

`testing/kata/` (this repo) boots real VMs locally - real guest kernel, real
systemd - in ~6 seconds each; `krikri-role-tester`'s `kata` backend drives it
directly (`kata-host.sh up|down` per slot, octets `10 + 2N`/`11 + 2N`,
`10.99.<octet>.2`). Read `testing/kata/README.md` before relying on it: the
setup has several non-obvious failure modes, all documented there with the
reason, and one of them (recreating a netns under a live VM) hangs `ctr`
in a way no timeout escapes.

Use the Kata backend when the round needs a real **kernel** -
`sysctl:`/`os_hardening`, `modprobe`, netfilter below `--cap-add=NET_ADMIN`,
filesystem modules - which is exactly what containers cannot do and what has
left those roles unverified. For plain systemd, `podman run --systemd=always`
is simpler and already sufficient (the 0.9.727-0.9.728
`service:`/`service_facts:` work was verified that way).

## Credentials for the benchmark workflow

See `CLAUDE.local.md` (gitignored, not part of this public repo) for where the
Atlantic.net API keys used in the real-host benchmark workflow come from.

## Docs that must stay in sync

- `KNOWN_MISSING.md` - two lists plus per-round narrative. **Open gaps** (top) is defects with an
  unknown or unfinished fix and should stay short; **Deliberate limits** (bottom) is decisions
  already made, with the reasoning attached. Keep the two apart - an item that stops being a defect
  moves down or gets deleted, it does not linger at the top, and a fixed item's narrative lives in
  `git log`, never here. Per-round narrative sits between them, newest first.
- `ROLES_TESTED.md` - one-line current status per role tested, no history, cold/warm timing
  included on every row. Also owns the 10-role benchmark comparison table (moved here from
  `README.md` - detailed per-role numbers belong here, not in the README).
- `README.md` - version badge only for round history; no "Recent changes" section (removed - round
  history lives in `git log`, not here). The README leads with "How this differs from real
  Ansible"/"What's missing"/"Performance" rather than round history - those sections should stay
  current-state-focused, not accumulate a changelog.

Don't let these drift from `git log`/reality - they're the first thing a new session (or this one,
next time) reads to avoid re-deriving context that already exists.
