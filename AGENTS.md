# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo. See the parent
`git_work/AGENTS.md` (or its `CLAUDE.md`, depending on the tool) for the
cross-repo Dirless-workspace picture (this repo is a standalone shard, not
part of that platform).

## What this is

`krikri-playbook` (binary name `krikri-playbook`) is a from-scratch
reimplementation of `ansible-playbook` in Crystal: parses Ansible
playbooks/roles/inventories and executes them, aiming for full
behavioral parity with `ansible-core` - not just "the common
cases work." Two Jinja2/expression evaluators exist side by side: a
hand-rolled `{{ }}` evaluator (`ExpressionEvaluator`/
`ConditionalEvaluator`/`ComparisonEvaluator`/`FilterEngine`, under
`src/krikri/variable_substitutor/`) for plain task-param substitution,
and **krikri-jinja** (`weirdbricks/krikri-jinja`, our own clean-room
Jinja2 engine shard) for real `.j2` template files, `{%`/`{#` block-tag
rendering, and every structured value the hand-rolled evaluator
delegates (`JinjaRenderer#render!`/`#evaluate_value!`,
`TemplateActionPlugin`). The hand-rolled evaluator falls back to /
delegates into krikri-jinja for anything it cannot answer itself, so the
same bug class (most often "recursive re-templating": a variable whose
own value is itself unrendered Jinja) can still surface in either -
when fixing a templating bug, check both.

Ansible's own filters, tests, lookups and `datetime` values are
registered on krikri-jinja's shared default engine in
`krikri_jinja_filters.cr`, `krikri_jinja_lookups.cr` and
`jinja_datetime.cr`; pure JSON-level implementations shared with
`FilterEngine` live in `variable_substitutor/filter_core.cr`. Variables
reach the engine lazily through `JinjaVarResolver` (one name prepared
per first read). An engine-level change (a new hook, a lexer/semantics
fix) goes in the krikri-jinja repo (sibling checkout
`../krikri-jinja-engine-registry`, branch `engine-registry`): add a spec,
bump its version, tag `v0.4.N`, push, then bump the `tag:` in this
repo's `shard.yml` and `shards update krikri-jinja`.

Each Ansible module is its own tiny compiled binary under `plugins/`,
uploaded to and executed on the target host (or run locally for
`ansible_connection=local`). `src/krikri/plugin_manager.cr`
handles upload/dispatch; `src/krikri/task_batcher.cr` groups
sequential tasks into one SSH round trip where safe.

## Licensing

krikri is GPL-3.0-or-later, the same license family as ansible-core,
ansible-lint and yamllint (GPLv3+), so matching them byte for byte, reading
their source for parity work and adopting their short messages and constant
tables is fine. Keep attribution honest: don't claim a clean-room origin for
this codebase (only krikri-jinja is clean-room), and see `NOTICE`. The
library shards (krikri-jinja, krikri-xml, ...) stay MIT; GPL krikri may use them.

## Build & test

```bash
./build.sh                          # builds bin/krikri-playbook + all bin/plugins/* (mtime-skip, safe to always run)
./build.sh --release                # only near the end of a work session - slow, not needed for correctness iteration
                                     #   also rebuild --release before any krikri-role-tester round whose
                                     #   *timing* matters: `--version`'s `Build:` line reports debug/release,
                                     #   and a debug binary runs ~1.8x slower wall-clock on identical work -
                                     #   `krikri-role-tester` warns (not refuses) when it detects one, and records
                                     #   the build type, commit and a stale-binary check in the run's `versions.txt`
scripts/minitest.sh                 # the full minitest suite under test/
scripts/minitest.sh -- -p 4         # same suite on 4 worker fibers (the suite is
                                     #   IO/sleep-bound, so tests genuinely overlap;
                                     #   parallel-safety rules in test/minitest_helper.cr)
scripts/minitest.sh test/unit/foo_test.cr   # one file
scripts/minitest.sh -- -n /pattern/ # a subset by test-name regex
ameba                               # lint
```

**Test framework**: the whole suite is
[minitest.cr](https://github.com/ysbaddaden/minitest.cr) under `test/`
(`unit/`, `integration/`, `lint/`; `describe`/`it` with
`must_equal`/`assert_*`). Minitest randomizes test order by default, so
tests must not depend on each other. Minitest has no per-file discovery,
so `scripts/minitest.sh` globs `test/**/*_test.cr` into a generated
entrypoint (`.minitest_all.cr`, gitignored), builds one hash-gated binary
(`.minitest_all.bin`), and runs it; passing a single existing file to the
script runs that file directly, and anything after `--` goes to
`Minitest.run`.

**Live docker tests are off by default**: the `docker_compose_v2` and
`docker_container published_ports` tests bring real podman/compose projects up (~135s of a
~230s suite) and skip unless `KRIKRI_DOCKER_TESTS=1`. CI always sets it;
`krikri-fix-issues` sets it when a fix touches docker code. Run them locally with
`KRIKRI_DOCKER_TESTS=1 scripts/minitest.sh -- -p 4`.

**Parallel-safety rules** (required for `-- -p N`; full detail in
`test/minitest_helper.cr`):
- Per-test scratch space comes from `PluginSpecHelper.tmp_path` - a
  private subtree under `test/tmp/p/<nonce>`, scoped by the `run_one`
  hook to the running test's fiber.
- Tests that touch `ENV` or other process-wide state call `serial!` in
  their `describe` body: they then serialize on
  `PluginSpecHelper::STATE_MUTEX` across setup, body AND teardown, and
  before_each/after_each ENV pinning is covered too. Helpers that need
  the same guarantee take that mutex themselves (it is reentrant).
- `PluginSpecHelper.run`/`run_raw` accept `chdir:`,
  `before_input:` and `umask:` parameters - use them instead of doing it
  yourself: never `Dir.cd` the suite process, never `LibC.umask` the
  suite process (umask is process-wide and leaks across workers), and
  never make process-wide ENV changes outside a `serial!` test.
- When draining a child process's stdout, drain to EOF BEFORE
  `Process#wait` (see `run_plugin_with_timeout`): `#wait` closes the
  process's pipes, so a drain fiber still reading dies on "Closed
  stream" and the test hangs or sees truncated output. Never
  `LibC.close` an fd an IO object wraps - its GC finalizer closes the
  (by then reused) fd number again.
- Every `it` needs a name unique within its `describe` (and top-level
  `describe` subjects must be unique across `test/`): minitest turns
  names into methods, so a bare `it { }` or a duplicate would silently
  replace a sibling - `test/minitest_helper.cr` makes both a compile
  error.

**Always run `./build.sh`**, never a bare `crystal build krikri-playbook.cr` alone, before trusting a
"still broken" result against a real host - plugin binaries compile separately from the main
executable and a manual build of just one leaves the other stale.

**Adding a new plugin** (e.g. a new module) needs registering in *two* places:
1. `plugins/<name>.cr` - the plugin itself (see any existing one for the `BasePlugin` pattern).
2. `src/krikri/playbook_parser.cr`'s `AVAILABLE_PLUGINS` array - module-name dispatch.

`build.sh` auto-discovers plugins from `plugins/*.cr`, so the old third-place
registration (and its past sync drift, e.g. the `apt_key` omission) is gone.

## Version bumping

`src/krikri/version.cr`'s `VERSION` gets bumped with every commit that changes engine/plugin
behavior (not doc-only commits). One bump per logical fix or tightly-related group of fixes found in
the same investigation - not one per file touched.

## The real-host benchmark-round workflow

This is the primary way bugs get found - unit tests alone (6000+) have never been enough; every real
round against a production Ansible role finds more. Read `KNOWN_MISSING.md`'s own intro and skim the open
[GitHub issues](https://github.com/weirdbricks/krikri/issues) (`gh issue list`) before starting a round.

Rounds are driven by **`krikri-role-tester`** (sibling repo,
`../krikri-role-tester`), a Crystal app that replaced the old shell drivers
(`testing/kata/run_role.sh`, `run_batch.sh`, and the various
`~/scratch/bench/run_role*.sh` scripts). Read its own `README.md` first - it
covers the queue-file format, the scheduler model, results layout, and both
backends in detail. The summary below is only what's specific to using it
from this repo.

**The user runs `krikri-role-tester` themselves; Claude never starts it** (it
provisions real servers, and babysitting it burned tokens). Claude's part
starts from the results directory the user hands over - the `triage-round`
skill's first step is to ask for it, and it documents the layout.

1. **Check `ROLES_TESTED.md` first** for a role shortlist - avoids re-discovering Galaxy-404s
   (`geerlingguy.mongodb`/`.consul`/`.golang` don't exist anymore) or re-verifying already-clean
   roles as if new (unless deliberately re-checking after something made a host suspect).

2. **Batch phase (run by the user):** rebuild `bin/krikri-playbook --release` first (the
   run records the binary's version and commit in `versions.txt`, and flags a binary older
   than its checkout's HEAD), then either let the tool pick new roles or re-run a list:

       ./bin/krikri-role-tester --auto-mode --roles=600       # new roles from Galaxy
       ./bin/krikri-role-tester --auto-mode --queue roles.txt # re-run specific roles

   `--auto-mode` skips roles already in `ROLES_TESTED.md` or an earlier `logs___*`
   dir, drops Galaxy 404s before provisioning, splits ubuntu/rocky 50-50, and writes
   everything to a fresh `logs___<epoch>/<role>/`. It is Atlantic.net only; the account's
   server cap is 25 with 2 reserved for Dirless, so `--atlantic-hosts` defaults to 22
   (11 role pairs) - lower it if another batch is running. Each role has staged time
   budgets (terraform 5m, ssh 5m, cold+warm 30m) and a watchdog kills silent rounds.
   Per role it runs cold + warm on both engines and compares exit codes, per-task results
   and raw output byte for byte (`compare`, `compare.txt`, `compare_<phase>.diff`) besides
   the PLAY RECAP counters (`SUMMARY|` lines). It also handles the known plugin-upload
   UNREACHABLE race (same-host retry, up to 3) itself - see its README. Do **not** make
   engine code changes during this phase.
   - Any divergence still needs a minimal repro confirmed against `ansible-playbook` (not
     assumed) before treating it as a krikri-playbook bug - plenty of "bugs" turn out to be broken
     upstream repos, missing Galaxy roles, or role-side gaps (e.g. `php-mysql`'s own repo ships no
     `vars/Debian.yml` at all) that affect Ansible identically.
   - **Coverage bar: 100% for core (`ansible.builtin`) modules, 100% for community modules krikri
     has deliberately chosen to support, and zero obligation for every other community module.**
     A divergence whose root cause is an unsupported community module doesn't count - not a bug to
     fix, not an open gap to log, not scope at all - regardless of whether the cause is a missing
     module (`COMMUNITY_MODULE_MISSING` in `krikri-role-tester`'s own classification) or a
     behavioral quirk in one it partially implements. Check whether the responsible module is core
     or on the supported list before spending investigation time on a divergence.

3. **Triage:** start from `<logs___dir>/report.txt` (one line per role, with a
   `bytes=IDENTICAL|DIFFERENT` suffix). Roles that are `bytes=IDENTICAL` need no reading.
   For the rest, read `<role>/compare.txt`, then `compare_<phase>.diff`, then the `.out`
   files around the named task. Then dedupe the collected divergences - if two or more
   roles hit the same root cause, that's one fix to make, not two. A difference in output
   *text* (e.g. Ansible's `Origin:` error context) is a real krikri gap, not something to
   mask; masks (`Compare::MASKS` in krikri-role-tester) are only for output that can never
   be identical. The `triage-round` skill walks through this and files GitHub issues for the confirmed root causes; the `work-issues` skill then picks issues to fix.

4. **Fix phase (serial):** apply fixes one at a time against the unit tests (concurrent edits to
   the same evaluator/plugin code aren't safe to parallelize even though the discovery phase is).
   Add a regression test where practically possible (some things - real dpkg/apt mutation, real
   crontab mutation, real pip installs - have no test at all by design; verify those live instead
   and say so in the commit message). Bump `VERSION` per logical fix or tightly-related group of
   fixes, run the full `scripts/minitest.sh -- -p 4` suite, and `./build.sh`.

5. **Confirm phase:** ask the user to re-run *only* the roles that diverged
   (`./bin/krikri-role-tester --auto-mode --queue <file>`, queue lines copied from the old
   `queue.txt`) against the rebuilt binary, and triage the new directory, before considering
   any fix done. `versions.txt` shows which krikri commit the re-run used.

6. Update `ROLES_TESTED.md` (the current-status table) and, if a deliberate limit was decided,
   `KNOWN_MISSING.md`, together in one commit; open/close GitHub issues for gaps (`Fixes #N` in the
   fixing commit, `gh issue create` for a confirmed unfixed divergence), covering the whole batch at once rather than
   per-pair; bump `README.md`'s version badge too.
   **Every role tested gets its own row in `ROLES_TESTED.md`'s table** (one role per row,
   not bundled into a shared "role / role / role" line even when several fail the same
   way) **and that row must include its cold/warm timing for both engines** - not just
   roles picked for a dedicated benchmark comparison. This is the only place per-role
   timings live (see `ROLES_TESTED.md`'s own note at the top). Older rows predating this
   convention (bundled entries, missing timings) are left as-is, not backfilled.

7. If a run was SIGKILLed, the user runs `bin/krikri-role-tester sweep <logs___dir>` (and
   `cleanup-orphans <logs___dir>`) to find rounds whose `run.log` never reached `DONE` and tear
   down their leftover terraform state / servers.

## Local Kata test hosts (retired)

`testing/kata/` booted real VMs locally (real guest kernel, real systemd) as
a `krikri-role-tester` backend. **Retired as of 2026-09-12** - not enough
value for the reliability cost (see `testing/kata/README.md`'s failure
modes, one of which hangs `ctr` with no timeout that escapes it). Kata
Containers itself (containerd, `/opt/kata`, the `containerd-shim-kata-v2`
binary) has been uninstalled from the dev laptop it ran on; the scripts
under `testing/kata/` are left in place for reference only, not runnable
without reinstalling Kata. Use Atlantic.net for rounds needing a real
kernel (`sysctl:`/`os_hardening`, `modprobe`, netfilter, filesystem
modules); for plain systemd, `podman run --systemd=always` remains
sufficient and unaffected by this.

## Credentials for the benchmark workflow

See `CLAUDE.local.md` (gitignored, not part of this public repo) for where the
Atlantic.net API keys used in the real-host benchmark workflow come from.

## Docs that must stay in sync

- **GitHub issues** - open gaps: defects with an unknown or unfinished fix. File one per root cause
  (label `divergence`/`bug`; `tracking` for long-running verification coverage), close with
  `Fixes #N`. No per-round narrative anywhere: it lives in `git log`.
- `KNOWN_MISSING.md` - **Deliberate limits** only: decisions already made, with the reasoning attached,
  plus test-environment notes. An item that turns out to be a defect becomes an issue and is deleted
  from here.
- `ROLES_TESTED.md` - one-line current status per role tested, no history, cold/warm timing
  included on every row. Also owns the 10-role benchmark comparison table (moved here from
  `README.md` - detailed per-role numbers belong here, not in the README).
- `README.md` - version badge only for round history; no "Recent changes" section (removed - round
  history lives in `git log`, not here). The README leads with "How this differs from
  Ansible"/"What's missing"/"Performance" rather than round history - those sections should stay
  current-state-focused, not accumulate a changelog.

Don't let these drift from `git log`/reality - they're the first thing a new session (or this one,
next time) reads to avoid re-deriving context that already exists.
