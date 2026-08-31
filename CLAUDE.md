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

0. **Check `KNOWN_MISSING.md`'s native-typing entry** for the pending
   passive frequency scan - it asks the round to grep the downloaded role
   set for one specific shape BEFORE running, without changing which
   roles the round picks. Cheap, and it is the open question blocking a
   decision on the last documented gap.
1. **Check `ROLES_TESTED.md` first** for a role shortlist - avoids re-discovering Galaxy-404s
   (`geerlingguy.mongodb`/`.consul`/`.golang` don't exist anymore) or re-verifying already-clean
   roles as if new (unless deliberately re-checking after something made a host suspect).
2. Provision a fresh 2-node Atlantic.net pair (`G3.2GB`, Ubuntu 22.04) - one host runs real
   `ansible-playbook`, the other runs the just-built `krikri-playbook`. Use a fresh host pair for
   every round (one role, or one small role batch run to completion) rather than reusing a pair
   across rounds - accumulated state (stale apt lists, port contention from earlier roles,
   occasional AppArmor/apt-key drift) starts producing environmental noise indistinguishable from
   real bugs the longer a pair stays alive. Destroy and reprovision between rounds even if it
   means more terraform apply/destroy cycles.
3. Run the SAME playbook against both. Any divergence needs to be reproduced with a minimal
   repro and confirmed against real `ansible-playbook` (not assumed) before treating it as a
   krikri-playbook bug - plenty of "bugs" turn out to be broken upstream repos, missing Galaxy
   roles, or role-side gaps (e.g. `php-mysql`'s own repo ships no `vars/Debian.yml` at all) that
   affect real Ansible identically.
4. **Test idempotency explicitly** (run the role twice) - a single successful run can hide a
   non-idempotency bug that only shows up on rerun (found this way more than once: `cron:`'s
   trailing-newline bug, `lineinfile`'s `!regexp` gate, `get_url`'s `force: true` always-changed).
5. Verify real service health (`systemctl is-active`, an actual health-check curl/config-validate
   command), not just the playbook's own exit code.
6. Fix, add a regression spec where practically possible (some things - real dpkg/apt mutation,
   real crontab mutation, real pip installs - have no spec at all by design; verify those live
   instead and say so in the commit message).
7. Bump `VERSION`, run the full `crystal spec` suite, `./build.sh`, redeploy the fixed binary,
   and re-verify live before considering the fix done.
8. Update `KNOWN_MISSING.md` (the running per-round narrative) and `ROLES_TESTED.md` (the
   current-status table) together in one commit; bump `README.md`'s version badge too.
   **Every role tested gets its own row in `ROLES_TESTED.md`'s table** (one role per row,
   not bundled into a shared "role / role / role" line even when several fail the same
   way) **and that row must include its cold/warm timing for both engines** - not just
   roles picked for a dedicated benchmark comparison. This is the only place per-role
   timings live (see `ROLES_TESTED.md`'s own note at the top). Older rows predating this
   convention (bundled entries, missing timings) are left as-is, not backfilled.
9. Destroy the hosts (`terraform destroy`), clean up `known_hosts`, shred the staged credentials
   `.env`.

## Credentials for the benchmark workflow

See `CLAUDE.local.md` (gitignored, not part of this public repo) for where the
Atlantic.net API keys used in the real-host benchmark workflow come from.

## Docs that must stay in sync

- `KNOWN_MISSING.md` - per-round bug narrative, newest first, no fixed-bug detail duplicated (that
  lives in `git log` commit messages).
- `ROLES_TESTED.md` - one-line current status per role tested, no history, cold/warm timing
  included on every row. Also owns the 10-role benchmark comparison table (moved here from
  `README.md` - detailed per-role numbers belong here, not in the README).
- `README.md` - version badge only for round history; no "Recent changes" section (removed - round
  history lives in `git log`, not here). The README leads with "How this differs from real
  Ansible"/"What's missing"/"Performance" rather than round history - those sections should stay
  current-state-focused, not accumulate a changelog.

Don't let these drift from `git log`/reality - they're the first thing a new session (or this one,
next time) reads to avoid re-deriving context that already exists.
