---
name: launch-roles
description: Run a full krikri-role-tester round end-to-end against real Ansible Galaxy roles — launch, monitor, triage, dispatch fixes, and confirm them. Use whenever the user asks to "launch roles", "run a round", "start a batch", "test some roles", or names specific roles/a role count to test against krikri-playbook vs real ansible-playbook. Covers picking roles, choosing a fresh round-start, fetching Atlantic.net credentials, respecting Atlantic.net's concurrency limit, running the batch, monitoring it to completion, triaging divergences, dispatching root-cause fixes to Crush, validating and landing each fix, confirming the fix against the real host, and syncing the round's docs. Atlantic.net only — the Kata backend is retired (not enough value for the reliability cost; see step 4).
---

# Launch roles (krikri-role-tester full round)

Drives an entire real-host benchmark round in
`/home/labros/git_work/krikri/CLAUDE.md`'s workflow: batch → monitor → triage
→ fix dispatch → validate/land → confirm → docs sync. Steps 1-7 are the
"batch phase" — no engine code changes during those. Steps 8 onward
(triage/fix/confirm) do change code, by design — that's the point of a full
round, not a deviation from it.

## 1. Determine the role list

If the user named specific roles (as arguments or in their message), that
answers everything below — skip straight to using those roles.

Otherwise ask, in order, skipping any question the request already answers:

**Question 1:** "New roles, or already-tested roles?"

**Question 2:** "How many roles do you want to run?"

### New roles

Source fresh candidates from the Galaxy top-download list, diffed against
every role already in `ROLES_TESTED.md` so nothing gets re-tested:

```bash
# Extract every already-tested role name (case matters for the dedup below)
grep -oP '^\| `\K[^`]+(?=` \|)' ROLES_TESTED.md | sort -u > /tmp/tested.txt

# Page through Galaxy's top-download list. Use summary_fields.namespace.name,
# NOT github_user/username — a role's install-time namespace can differ from
# its GitHub owner after a Galaxy-side rename/migration, and github_user
# produced a ~36% GALAXY_MISSING rate (plain 404s) in an earlier batch.
for page in $(seq 1 <enough-pages-for-3x-the-batch-size>); do
  curl -s "https://galaxy.ansible.com/api/v1/roles/?order_by=-download_count&page_size=100&page=$page" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['results']:
    ns = r.get('summary_fields',{}).get('namespace',{}).get('name') or r.get('github_user')
    print(f\"{ns}.{r['name']}\")
"
  sleep 0.3
done >> /tmp/galaxy_all.txt

# Case-insensitive dedup against already-tested roles — Galaxy's namespace
# field is lowercase-canonical, but ROLES_TESTED.md rows preserve whatever
# casing the original queue file used (e.g. `Appsilon.mount_efs`), so a
# case-sensitive diff re-tests the same role under a different spelling.
awk 'NR==FNR{tested[tolower($0)]=1; next} !(tolower($0) in tested) && !seen[tolower($0)]++' \
  /tmp/tested.txt /tmp/galaxy_all.txt > /tmp/galaxy_new_ranked.txt
```

Take the top N from `/tmp/galaxy_new_ranked.txt` (already ranked by download
count, highest first). For a split-OS batch (e.g. 400 roles = 200
ubuntu + 200 rocky), just take the first half/second half — no need to
re-rank per OS.

### Already-tested roles

Pull from `ROLES_TESTED.md`'s current-status table — this is a deliberate
re-check (e.g. after a fix that should have changed a role's DIVERGENT
status, or after something made a host suspect), not new-role discovery. Ask
which rows/status to target if it's not obvious from context (e.g. "all
DIVERGENT roles" vs. specific named roles). If the target is a filter like
"all DIVERGENT roles" rather than a fixed list, the count is whatever
matches that filter — skip Question 2 in that case, it's already answered.


## 2. Pick a fresh round-start

Round numbers must never be reused, especially not from a killed/interrupted
batch — relaunching at a dead batch's `--round-start` hits 100% instant
`SSH_TIMEOUT` against now-torn-down hosts (see memory:
`dont-reuse-round-numbers-after-kill`).

Find the highest round number already used and start comfortably above it:

```bash
ls ~/scratch/krt-results 2>/dev/null | sed -E 's/^([0-9]+)_.*/\1/' | sort -n | tail -1
```

Round up to a clean multiple (e.g. last was `700443` → use `701000`) so the
new round's own numbers stay easy to read back out of `ROLES_TESTED.md` later.

## 3. Fetch Atlantic.net credentials

Every round uses Atlantic.net now (Kata is retired — see step 4), so this
step is never skipped. Per `CLAUDE.local.md`:

```bash
ATLANTICNET_ACCESS_KEY=$(/usr/local/bin/keypass-tool.sh 2>/dev/null | keepassxc-cli show -s "$DB" atlanticnet --attributes AccessKey 2>/dev/null)
```

- **`-s`/`--show-protected` is required** — without it `keepassxc-cli show`
  silently returns the literal string `PROTECTED` instead of the real value,
  which breaks `terraform apply` with an invalid-API-key error that looks
  unrelated to credentials.
- Always redirect stderr to `/dev/null`, **never `2>&1`** — the "Enter
  password to unlock" prompt text otherwise gets captured into the credential.
- Maps to `ATLANTICNET_ACCESS_KEY`/`ATLANTICNET_PRIVATE_KEY` (not
  `_USERNAME`/`_PASSWORD`).
- See `CLAUDE.local.md` for the exact KeePass DB path and entry name — read it
  rather than hardcoding here, since it's gitignored and may change.

## 4. Respect Atlantic.net's concurrency limit

**Kata is retired as a backend for this skill** — not enough value for its
reliability cost (real incident: a 400-role round on 2026-09-12 hit 47
BOOT_FAILED roles, all kata, all clustered near the end of one batch — pure
infra flakiness, not signal about krikri). Always pass `--backend atlantic`
explicitly; never pass `--kata-hosts` or rely on the tool's default
`--backend both`. Ignore any older `kata-concurrency-limit`/
`kata-teardown-devshm-leak` memory entries when planning a round — they're
about a backend this skill no longer uses.

- **Atlantic.net:** account cap is 25 servers, 2 reserved for Dirless — keep
  total concurrency (this batch + anything already running) ≤ 22
  (memory: `atlanticnet-server-limit`). Check for already-running batches
  first (`ps aux | grep krikri-role-tester`, or ask the user) before assuming
  the full 22 is free.
- **Sweep before launching, every time**, even if nothing looks obviously
  wrong: `bin/krikri-role-tester sweep ~/scratch/krt-results` — a prior
  session's crash or interrupted run can leave orphaned Atlantic.net servers
  that silently eat into the 22-server budget above. Also check
  `ps aux | grep krikri-role-tester` for anything already running before
  computing how much of the budget is actually free.

`--atlantic-hosts` now **defaults to 22** (the usable ceiling itself) as of
`krikri-role-tester`'s own default — no more manually guessing a smaller
number and re-deriving the ceiling at launch time. Only pass `--atlantic-hosts`
explicitly to go *below* 22 (e.g. sharing the budget with another
already-running batch — see the concurrency check above).

## 5. Write the queue file

One role per line in the scratchpad directory:

```
geerlingguy.docker
geerlingguy.nginx
geerlingguy.apache
```

Backend hints (`kata`/`atlantic`/`any`) in the queue file format are now
moot since every run is atlantic-only — don't add them, plain role names
are enough. (`krikri-role-tester` still parses the hint field if an older
queue file has one; it's just never needed for a new one.)

## 6. Run it

```bash
cd /home/labros/git_work/krikri-role-tester
ATLANTICNET_ACCESS_KEY=... ATLANTICNET_PRIVATE_KEY=... \
  bin/krikri-role-tester run <queue-file> \
    --backend atlantic --atlantic-hosts <N> \
    --results-dir ~/scratch/krt-results --round-start <fresh-round>
```

Launch as a background command (this is a long-running batch — provisioning,
cold+warm runs, teardown per role). Tell the user the round range and where
results will land, then continue on to monitoring (step 7) — the rest of
this round (triage, fix, confirm) is this skill's job too, not a handoff.

Record `round_start` and `total` (the queue file's line count) now — steps
7-8 both need them to know which round directories belong to this batch.

If the run needs to be interrupted, use plain `kill <pid>` (SIGTERM) for a
graceful shutdown — never `kill -9` — and mention
`bin/krikri-role-tester sweep ~/scratch/krt-results` as the recovery path if
it ever does get SIGKILLed or the machine crashes.

## 7. Monitor progress

While the batch runs, check in roughly every 3 minutes (poll via
`ScheduleWakeup`/`Monitor` rather than a blocking `sleep` loop) and report
progress as `<done>/<total>`, e.g. `5/20 done`:

```bash
total=$(wc -l < <queue-file>)
round_end=$((round_start + total - 1))
done=$(for round in $(seq "$round_start" "$round_end"); do
  ls -d ~/scratch/krt-results/"${round}"_*/ 2>/dev/null
done | xargs -I{} sh -c 'grep -q DONE "{}/run.log" 2>/dev/null && echo done' | wc -l)
echo "$done/$total done"
```

**Do not glob `<round-start>*`** — that matches on string prefix, so
round-start `701000` would match a directory named `7010005_...` but miss
`701001`-`701499`, which is where most of a real batch's rounds actually
live. Iterate the numeric range `round_start..round_start+total-1` instead
(round numbers are assigned roughly sequentially per queued role, one round
per role); `grep -l`/`grep -q DONE` counts a directory once it's reached
`DONE`, regardless of final status.

Each check-in should also confirm the batch is actually healthy, not just
counting up slowly:

- **No unexpected errors**: skim the tail of active `run.log` files (or
  `ps aux | grep krikri-role-tester` to confirm the process is still alive)
  for anything beyond the expected `SUMMARY|`/`DONE` lines — a crash, a
  Terraform auth failure, or a repeating same-host `UNREACHABLE` retry loop
  all warrant flagging to the user immediately rather than waiting for the
  next 3-minute tick.
- **Actual progress, not a stall**: the `done` count (or the set of active
  round directories' `run.log` mtimes) should be advancing between checks.
  If it's flat for more than one or two ticks with the process still
  running, that's worth surfacing — don't just keep silently re-polling.

Stop monitoring once `done == total` (or the process has exited) and report
the final tally before moving to triage.

## 8. Triage

Once the batch finishes, run triage automatically — don't ask the user
whether to do it:

```bash
round_end=$((round_start + total - 1))  # same derivation as step 7
bin/krikri-role-tester report ~/scratch/krt-results --round-start "$round_start" --round-end "$round_end"
```

Then, per `CLAUDE.md`'s triage step:

- Dedupe the divergences — if two or more roles hit the same root cause,
  that's one fix to make, not two.
- For each divergence, confirm it's a real `krikri-playbook` bug with a
  minimal repro against real `ansible-playbook` before treating it as one —
  plenty of "bugs" turn out to be broken upstream roles, missing Galaxy
  roles, or role-side gaps that affect real Ansible identically.
- Report the triaged results to the user (CLEAN count, DIVERGENT roles with
  their deduped root causes, any BLOCKED/GALAXY_MISSING roles) — this is
  where the user's input is actually needed (deciding what's worth fixing
  now vs. later), not on whether triage should run at all.

## 9. Dispatch root causes to Crush

Once triage has a deduped list of confirmed root causes, start sending them
to Crush for investigation/fix automatically — don't ask the user for
permission to begin this.

Claude is the dispatcher, not a bystander, for each root cause:

1. **Create the worktree yourself** (`git worktree add`) before handing off
   — never ask Crush to create its own. One fresh worktree per root cause;
   never reuse one across two different fixes running concurrently.
2. Right before dispatching into a worktree that's been sitting, `git merge
   --ff-only main` in it first — an earlier fix may have already merged and
   bumped `VERSION`/`KNOWN_MISSING.md`, and dispatching against a stale base
   guarantees a collision later.
3. Dispatch via `mcp__crush-api__crush_run` with the root cause, a minimal
   repro, and the affected role(s) as context.
4. **Max 2 concurrent Crush tasks against this repo at any time** — more
   crashes the host (Crystal builds are CPU/memory-heavy). Queue the rest;
   launch the next one only once a running slot frees up.

Fix/confirm phases (steps 4-5 of the benchmark-round workflow in
`CLAUDE.md`) still apply per fix — this step just means dispatch starts
immediately after triage instead of waiting for the user to say "go ahead."

## 10. Validate every completed Crush job

For every Crush task that finishes, validate it before it goes anywhere near
`main` — **only Claude commits and pushes, never Crush, and never without
this validation**:

1. Read the diff as an outside reviewer would, not as a rubber stamp — check
   version bump present (`src/krikri/version.cr`), plugin
   three-place-registration if a plugin was touched, and a regression spec
   added where practical (or a stated reason in the intended commit message
   if not, per `CLAUDE.md`).
2. Run `crystal spec` (full suite) and `./build.sh` — both must pass clean
   before anything is trusted.
3. If validation finds real problems, push back and fix by hand rather than
   deferring to Crush's implementation choices — Crush's output is a second
   opinion, not an approval to merge on its own.
4. Only once it checks out: Claude commits and pushes. Then delete the
   worktree — also Claude's job, not Crush's.

This applies to every job independently, even when 2 are running
concurrently — validate and merge one at a time (see the staleness gotcha
in the dispatch step above: a second worktree merging after the first may
need its `VERSION`/`KNOWN_MISSING.md` bump renumbered by hand).

## 11. Confirm each fix against the real host

Passing `crystal spec`/`./build.sh` proves the fix doesn't regress anything
covered by unit specs — it does **not** prove the original divergence is
actually gone. Per `CLAUDE.md`'s confirm phase, after a fix for a role is
merged to `main`:

1. Build a fresh queue file containing **only the role(s) that diverged
   because of this root cause** (not the whole original batch).
2. Pick another fresh, never-used round-start (same rule as step 2).
3. Re-run via `bin/krikri-role-tester run` against the freshly rebuilt
   binary, then `report` on just that round range.
4. The role must come back CLEAN on both cold and warm before the fix is
   considered done. If it's still DIVERGENT, the root cause wasn't fully
   fixed — treat it as a new investigation, not a docs update.

Do this per fix as it lands, not batched at the end — a later fix could
otherwise mask whether an earlier one actually worked.

## 12. Sync round docs

Once every dispatched fix is merged and confirmed, update the round's
tracking docs together in one commit (per `CLAUDE.md`'s "Docs that must stay
in sync"):

- **`KNOWN_MISSING.md`**: add this round's narrative entry (newest first,
  between the two lists) covering the whole batch; move/delete any "Open
  gaps" entries that this round's fixes resolved.
- **`ROLES_TESTED.md`**: one row per role tested this round — never bundled
  — each with cold/warm timing for both engines. Every role from the
  original batch queue gets a row, including ones that stayed CLEAN, not
  only the ones that needed fixes.
- **`README.md`**: bump the version badge to match the final `VERSION`
  reached this round.

This is the step that closes out the round — after this, `ROLES_TESTED.md`
and `git log` are the source of truth for what this round did, matching how
every prior round was documented.
