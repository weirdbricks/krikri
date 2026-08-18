# CLAUDE.md

Guidance for Claude Code working in this repo. See the parent
`git_work/CLAUDE.md` for the cross-repo Dirless-workspace picture (this
repo is a standalone shard, not part of that platform).

## What this is

`crystal-play` (binary name `crystal-ansible`) is a from-scratch
reimplementation of `ansible-playbook` in Crystal: parses real Ansible
playbooks/roles/inventories and executes them, aiming for full
behavioral parity with real `ansible-core` - not just "the common
cases work." Two independent Jinja2/expression evaluators exist side
by side: a hand-rolled `{{ }}` evaluator (`ExpressionEvaluator`/
`ConditionalEvaluator`/`ComparisonEvaluator`/`FilterEngine`, under
`src/crystal_play/variable_substitutor/`) for plain task-param
substitution, and the vendored `Crinja` shard (`CrinjaRenderer`,
`TemplateActionPlugin`) for real `.j2` template files and `{%`/`{#`
block-tag rendering. They do **not** share implementation - the same
bug class (most often "recursive re-templating": a variable whose own
value is itself unrendered Jinja) gets found and fixed independently in
each, repeatedly. When fixing a templating bug, check both.

Each Ansible module is its own tiny compiled binary under `plugins/`,
uploaded to and executed on the target host (or run locally for
`ansible_connection=local`). `src/crystal_play/plugin_manager.cr`
handles upload/dispatch; `src/crystal_play/task_batcher.cr` groups
sequential tasks into one SSH round trip where safe.

## Build & test

```bash
./build.sh                          # builds bin/crystal-ansible + all bin/plugins/* (mtime-skip, safe to always run)
./build.sh --release                # only near the end of a work session - slow, not needed for correctness iteration
crystal spec                        # full suite
crystal spec spec/unit/foo_spec.cr  # one file - NOTE: some files fail in isolation (a pre-existing
                                     #   require-ordering artifact, not a real regression) - always
                                     #   confirm any single-file failure against the full `crystal spec` run
crystal spec spec/foo_spec.cr:42    # one example
ameba                               # lint
```

**Always run `./build.sh`**, never a bare `crystal build crystal-play.cr` alone, before trusting a
"still broken" result against a real host - plugin binaries compile separately from the main
executable and a manual build of just one leaves the other stale.

**Adding a new plugin** (e.g. a new module) needs registering in *three* places, easy to
miss one:
1. `plugins/<name>.cr` - the plugin itself (see any existing one for the `BasePlugin` pattern).
2. `src/crystal_play/playbook_parser.cr`'s `AVAILABLE_PLUGINS` array - module-name dispatch.
3. `build.sh`'s `PLUGINS` array - or `./build.sh` silently never rebuilds it. (This list was
   already found out of sync once - `apt_key` had no entry despite a real compiled binary - so
   don't assume it's currently complete without checking.)

## Version bumping

`src/crystal_play/version.cr`'s `VERSION` gets bumped with every commit that changes engine/plugin
behavior (not doc-only commits). One bump per logical fix or tightly-related group of fixes found in
the same investigation - not one per file touched.

## The real-host benchmark-round workflow

This is the primary way bugs get found - unit specs alone (900+) have never been enough; every real
round against a production Ansible role finds more. Read `KNOWN_MISSING.md`'s own intro before
starting a round.

1. **Check `ROLES_TESTED.md` first** for a role shortlist - avoids re-discovering Galaxy-404s
   (`geerlingguy.mongodb`/`.consul`/`.golang` don't exist anymore) or re-verifying already-clean
   roles as if new (unless deliberately re-checking after something made a host suspect).
2. Provision a fresh 2-node Atlantic.net pair (`G3.2GB`, Ubuntu 22.04) - one host runs real
   `ansible-playbook`, the other runs the just-built `crystal-ansible`. Never reuse a host pair
   across more than a handful of role batches - accumulated state (stale apt lists, port
   contention from earlier roles, occasional AppArmor/apt-key drift) starts producing
   environmental noise indistinguishable from real bugs past that point.
3. Run the SAME playbook against both. Any divergence needs to be reproduced with a minimal
   repro and confirmed against real `ansible-playbook` (not assumed) before treating it as a
   crystal-ansible bug - plenty of "bugs" turn out to be broken upstream repos, missing Galaxy
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
   current-status table) together in one commit; update `README.md`'s version badge and
   "Recent changes" section too.
9. Destroy the hosts (`terraform destroy`), clean up `known_hosts`, shred the staged credentials
   `.env`.

## Credentials for the benchmark workflow

Atlantic.net API keys come from KeePass (`~/Dropbox/Dirless/DirlessPasswords.kdbx`, `atlanticnet`
entry) via `/usr/local/bin/keypass-tool.sh` piped into `keepassxc-cli` - always redirect its
stderr to `/dev/null`, never `2>&1`, or the "Enter password to unlock" prompt text gets captured
into the credential itself. Maps to `ATLANTICNET_ACCESS_KEY`/`ATLANTICNET_PRIVATE_KEY` (not
`_USERNAME`/`_PASSWORD`).

## Docs that must stay in sync

- `KNOWN_MISSING.md` - per-round bug narrative, newest first, no fixed-bug detail duplicated (that
  lives in `git log` commit messages).
- `ROLES_TESTED.md` - one-line current status per role tested, no history.
- `README.md` - version badge + a short rolling summary of the most recent rounds in "Recent
  changes" (keep it short - 5-6 entries; older history lives in `git log`, not here). The README
  leads with "How this differs from real Ansible"/"What's missing"/"Performance" rather than
  round history - those sections should stay current-state-focused, not accumulate a changelog.

Don't let these drift from `git log`/reality - they're the first thing a new session (or this one,
next time) reads to avoid re-deriving context that already exists.
