---
name: launch-roles
description: Triage the results of a krikri-role-tester run and drive the fixes — read the run's results directory (logs___<epoch>), skip byte-identical roles, group the rest by root cause, dispatch root-cause fixes to Crush, validate and land each fix, and have the user re-run to confirm. Use whenever the user asks to "launch roles", "run a round", "triage a batch", "look at the results", "check the logs___ dir", or names a results directory. The user runs krikri-role-tester themselves; this skill never starts it. Its first step is always to ask for the results directory.
---

# Triage a krikri-role-tester run

The user runs `krikri-role-tester` on their own (typically overnight, as
`./bin/krikri-role-tester --auto-mode --roles=N`). **Never start it
yourself** — not `run`, not `--auto-mode`, not a re-run. It provisions real
servers, and polling it is exactly the token burn this workflow replaces. Your
job starts after it has produced a results directory.

Steps 1-8 are read-only investigation. Steps 9 onward change code, by design.

## 1. FIRST: ask for the results directory

Before anything else — before reading `ROLES_TESTED.md`, before looking at the
repo — get the path to the results directory:

> Which results directory should I triage? (the `logs___<epoch>` directory
> the tool printed as `logs: …` / `report: …`)

Skip the question only if the user's message already contains the path.

If the user asked to *launch* or *run* roles, do not do it: give them the
command (`./bin/krikri-role-tester --auto-mode --roles=<N>`, add
`--queue <file>` to re-run specific roles) and ask them to come back with the
directory when it finishes.

Check the directory before trusting it:

```bash
ls <dir>
```

- `report.txt` present → the run finished. Normal case.
- `report.txt` missing but role dirs present → the run is still going or was
  killed. Say so, and ask whether to triage the finished rounds only (those
  whose `run.log` contains `DONE`).
- Directory missing or empty → ask again; do not guess another path.

## 2. What the directory contains

```
logs___<epoch>/
  versions.txt          what produced this run: tool, krikri binary + checkout
                        commit, ansible, terraform
  queue.txt             the roles tested, one "role any <ubuntu|rocky>" per line
                        (feed it back with --auto-mode --queue to re-run)
  rejected_roles.txt    candidates dropped before testing (would not install)
  report.txt            one line per role - START HERE
  <role>/               one directory per role (role name with . and / as _)
    meta                round=, backend=, role= (original name)
    status              final status marker (see step 4)
    run.log             timeline; ends with DONE; has the versions: line, the
                        SUMMARY| lines and COMPARE| lines
    summary.txt         the four SUMMARY| lines only
    compare             IDENTICAL or DIFFERENT (byte comparison verdict)
    compare.txt         per phase: verdict, then each difference
    compare_cold.diff   unified diff ansible vs krikri (only if cold differs)
    compare_warm.diff   same for warm
    cold_ansible.out    raw engine output
    cold_krikri.out
    warm_ansible.out
    warm_krikri.out
    galaxy_install.log  ansible-galaxy output
    work/               site.yml, inv_ansible.ini, inv_krikri.ini, roles/, tf/
```

Roles that never got far enough (blocked, timed out) will lack some files —
that is information, not an error.

`report.txt` lines look like:

```
round29862900 | justin_p.posh5 | DIVERGENT ansible[ok=1 changed=0 unreachable=0 failed=1 skipped=0] vs krikri[ok=1 ... failed=0 skipped=6] | cold ansible=5.9s krikri=6.7s warm ansible=4.7s krikri=0.5s | bytes=DIFFERENT
```

`SUMMARY|role|phase|engine|rc=N|time=S|ok=.. changed=.. unreachable=.. failed=.. skipped=..`
(engine is `ansible` or `krikri`; phase is `cold` or `warm`).

**Older results** (before 0.1.0) use `<round>_<backend>_<role>/` directory
names, `cold_py.out`/`cold_crystal.out` file names, `py`/`crystal` engine ids
and have no `compare*`/`versions.txt`. `krikri-role-tester report <dir>` still
reads them; there is no byte verdict, so triage by recap and the `.out` files.

## 3. Check what the run tested

Read `versions.txt` first and tell the user, in one line, what was tested:
krikri version, build type, commit, dirty or not.

- `warning:` / `stale_binary=yes` → the krikri binary is older than its
  checkout's HEAD commit. Fixes already merged may not be in it. Tell the
  user before triaging anything; a "divergence" may already be fixed. Ask
  whether to continue or have them rebuild and re-run.
- `Build: debug` → timings are ~1.8x slow; do not compare timings, and do
  not copy them into `ROLES_TESTED.md`.
- `commit: … (dirty …)` → note it; the result is not reproducible from the
  commit alone.

Record the commit — step 12's docs sync and any issue need it.

## 4. Read report.txt and tally

```bash
cut -d'|' -f3 <dir>/report.txt | awk '{print $1}' | sort | uniq -c | sort -rn
grep -c 'bytes=IDENTICAL' <dir>/report.txt
```

Statuses (the `status` file and the third column):

| Status | Meaning | Krikri signal? |
|---|---|---|
| `CLEAN` | recap counters match in cold and warm | maybe — check `bytes=` |
| `DIVERGENT` | recap counters differ | yes |
| `COMMUNITY_MODULE_MISSING` | only difference is a community module krikri does not track | deliberate gap, not a bug |
| `GALAXY_MISSING` | role would not install | no |
| `TF_APPLY_FAILED`, `SSH_TIMEOUT`, `BOOT_FAILED`, `NO_CAPACITY`, `CREDENTIALS_FAILED` | infra | no |
| `TIMED_OUT_OR_CRASHED` | an engine run or the watchdog hit its time budget | possibly a krikri hang — read both `.out` tails |
| `STOPPED` | run was interrupted | no |
| `ERROR` | tool error | no — report to the user |

`CLEAN` only means the five recap counters match. **Two engines that fail the
same way are `CLEAN`.** The `bytes=` suffix is the stricter check.

## 5. Skip what is byte-identical

A role with `bytes=IDENTICAL` matched on exit codes, per-task results and raw
output in both phases. **Do not read its logs.** Count it and move on. This is
the point of the byte comparison: it removes most roles from the LLM's
attention.

Everything else (`bytes=DIFFERENT`, or any non-CLEAN status) needs a decision.

The only normalisations are: both engines use the inventory alias
`testhost`, each side's own host IP becomes `<HOST_IP>`, and Ansible's
`[WARNING]: Host '…' is using the discovered Python interpreter…` line is
removed. Anything else that differs is real output.

## 6. Triage the rest, cheapest evidence first

For each non-identical role, read in this order and stop as soon as the cause
is clear:

1. `<role>/compare.txt` — a few lines. Per phase, the first-level reason:
   - `exit code differs: ansible=A krikri=B`
   - `block count differs: ansible=N krikri=M` (a different number of
     PLAY/TASK/RECAP sections — a task ran or was skipped on one side only)
   - `block N TASK [name] task results differ: ansible=[changed] krikri=[ok]`
   - `block N TASK [name] bytes differ (X B ansible, Y B krikri)` (same
     status, different text)
2. `<role>/compare_cold.diff` / `compare_warm.diff` — the exact lines. Read
   only the hunks `compare.txt` pointed at.
3. `<role>/cold_ansible.out` vs `cold_krikri.out` — only around the named
   task, not the whole file.
4. `<role>/work/roles/<role>/tasks/…` — the task source, when you need to know
   what the task does.

Do not read `run.log` unless status is blocked/timed out/ERROR; `summary.txt`
is already folded into `report.txt`.

## 7. Classify and deduplicate

Group roles by root cause — the same missing module, the same message format
difference, the same flag. One cause is one fix, not N.

For each group decide:

- **Real krikri bug** — a behavioural difference with the same input: a
  different exit code, a task `changed` on one side only, a task skipped or
  run on one side only, a different result structure. Confirm with a minimal
  repro against `ansible-playbook` (below) before treating it as one.
- **Krikri output gap** — same behaviour, different text: error context
  (Ansible prints `Origin: <file>:<line>:<col>` and a source excerpt under
  task errors), module error wording, extra warnings. **These are real
  differences. Do not propose masking them** — a mask hides the gap and makes a
  later fix undetectable. Masks are only for output that can never be identical
  (a host IP, a probe-driven Ansible warning); they live in `Compare::MASKS`
  in the krikri-role-tester repo, and adding one is the user's call.
- **Both engines fail the same upstream way** — a broken role (missing
  variable, removed `include:` action, dead URL). Not a krikri problem, but the
  *text* may still differ — then it is an output gap as above.
- **Untracked community module** — `COMMUNITY_MODULE_MISSING`; skip.
- **Infra / blocked** — not krikri signal; list them for the user.

To build a minimal repro: `ansible-galaxy role install <role> -p /tmp/galaxy-roles`
and a small `ansible_connection=local` playbook comparing `ansible-playbook`
with a freshly built `bin/krikri-playbook` (no VM needed). `ansible-playbook`
needs a pty here: `script -qec "ansible-playbook ..." /dev/null`.

## 8. Report to the user

Before dispatching anything, report — this is where the user's input is needed
(what is worth fixing now):

- What was tested (step 3) and the tally: `N identical / M different / K
  blocked`.
- Per root-cause group: one line of cause, the affected roles, one evidence
  path (`<dir>/<role>/compare_cold.diff`), and your classification.
- Blocked/GALAXY_MISSING roles, listed, not analysed.

Then continue with the groups the user wants fixed. If the user already said
to fix everything real, do not wait.

## 9. Dispatch root causes to Crush

Once there is a deduped list of confirmed root causes, send them to Crush
automatically.

Claude is the dispatcher, not a bystander, for each root cause:

1. **Create the worktree yourself** (`git worktree add`) before handing off
   — never ask Crush to create its own. One fresh worktree per root cause;
   never reuse one across two different fixes running concurrently.
2. Right before dispatching into a worktree that's been sitting, `git merge
   --ff-only main` in it first — an earlier fix may have already merged and
   bumped `VERSION`, and dispatching against a stale base guarantees a
   collision later.
3. Dispatch via `mcp__crush-api__crush_run` with the root cause, a minimal
   repro, the affected role(s), and the evidence paths from the results
   directory as context.
4. **Max 2 concurrent Crush tasks against this repo at any time** — more
   crashes the host (Crystal builds are CPU/memory-heavy). Queue the rest;
   launch the next one only once a running slot frees up.

See `fix-divergence` for the per-fix details (prompt contents, the
dropped-`return` warning, no `version.cr` edits in the worktree).

## 10. Validate every completed Crush job

For every Crush task that finishes, validate it before it goes anywhere near
`main` — **only Claude commits and pushes, never Crush, and never without
this validation**:

1. Read the diff as an outside reviewer would, not as a rubber stamp — check
   version bump present (`src/krikri/version.cr`), plugin
   three-place-registration if a plugin was touched, and a regression test
   added where practical (or a stated reason in the intended commit message
   if not, per `AGENTS.md`).
2. Run `scripts/minitest.sh -- -p 4` (full suite) and `./build.sh` — both must pass clean
   before anything is trusted.
3. If validation finds real problems, push back and fix by hand rather than
   deferring to Crush's implementation choices.
4. Only once it checks out: Claude commits and pushes. Then delete the
   worktree — also Claude's job, not Crush's.

Validate and merge one at a time (a second worktree merging after the first
may need its `VERSION` bump renumbered by hand).

## 11. Confirm each fix with a re-run — by the user

Passing the suite proves no regression; it does not prove the divergence is
gone. After a fix for a role is merged to `main`:

1. Tell the user the krikri binary must be rebuilt (`./build.sh --release`) —
   the run only tests what is in the binary. `versions.txt` of the next run
   will show the commit; check it contains the fix.
2. Write a queue file with **only the affected roles**, in the results
   directory's format (copy their lines from the old `queue.txt`, which keeps
   each role's OS):

   ```
   hoplacloud.fail2ban any rocky
   ```

3. Give the user the command and ask them to run it and send back the new
   directory:

   ```
   ./bin/krikri-role-tester --auto-mode --queue <queue-file>
   ```

4. Back at step 1 with the new directory. The role must come back
   `bytes=IDENTICAL` (or, if the remaining difference is a *known, accepted*
   output gap, say so explicitly). If it is still different, the root cause
   was not fully fixed — treat it as a new investigation.

Do this per fix as it lands, not batched at the end.

## 12. Sync round docs

Once every dispatched fix is merged and confirmed, update the tracking docs
together in one commit (per `AGENTS.md`'s "Docs that must stay in sync"):

- **GitHub issues**: file one issue per unfixed root cause (`gh issue create`,
  label `divergence`), and make sure each merged fix's commit says `Fixes #N`.
  Include the krikri commit from `versions.txt` and the evidence path. No
  per-round narrative is written anywhere; `git log` is the record. Only
  touch `KNOWN_MISSING.md` if a deliberate limit was decided.
- **`ROLES_TESTED.md`**: one row per role tested — never bundled — each with
  cold/warm timing for both engines (from the `report.txt` line). Every role
  from `queue.txt` gets a row, including ones that stayed CLEAN or
  byte-identical. Skip timings from a debug build.
- **`README.md`**: bump the version badge to match the final `VERSION`
  reached this round.

This closes out the round — after this, `ROLES_TESTED.md` and `git log` are
the source of truth for what the round did.
