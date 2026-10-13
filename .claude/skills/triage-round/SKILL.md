---
name: triage-round
description: Triage the results of a krikri-role-tester run - read the run's results directory (logs___<epoch>), skip byte-identical roles, group the rest by root cause, report, and offer to file one GitHub issue per root cause. Triage only: it never fixes anything (fixing is the `work-issues` skill, which reads the issues). Use whenever the user asks to "triage a batch", "triage a round", "look at the results", "check the logs___ dir", or names a results directory. The user runs krikri-role-tester themselves; this skill never starts it. Its first step is always to ask for the results directory.
---

# Triage a krikri-role-tester run

The user runs `krikri-role-tester` on their own (typically overnight, as
`./bin/krikri-role-tester --auto-mode --roles=N`). **Never start it
yourself** — not `run`, not `--auto-mode`, not a re-run. It provisions real
servers, and polling it is exactly the token burn this workflow replaces. Your
job starts after it has produced a results directory.

This skill triages; it does not fix. Steps 1-8 are read-only investigation, step 9
publishes GitHub issues (only on the user's say-so), step 10 records the round. Fixing
is the `work-issues` skill's job, driven by the issues step 9 files.

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

Record the commit — step 10 and any issue need it.

## 4. Read report.txt and tally

```bash
cut -d'|' -f3 <dir>/report.txt | awk '{print $1}' | sort | uniq -c | sort -rn
grep -c 'bytes=IDENTICAL' <dir>/report.txt
```

Statuses (the `status` file and the third column):

| Status | Meaning | Krikri signal? |
|---|---|---|
| `CLEAN` | recap counters match, nothing failed, and the output is byte-identical (tool >= 0.3.1) | no |
| `MATCHED_FAILURE` | both engines failed with the same recap counters (or the same non-zero rc before any recap) and the output is byte-identical | no - a broken role or host, same on both engines |
| `DIVERGENT` | recap counters differ, **or** the byte comparison is `DIFFERENT` even though the recaps match | yes |
| `COMMUNITY_MODULE_MISSING` | only difference is a community module krikri does not track | deliberate gap, not a bug |
| `GALAXY_MISSING` | role would not install | no |
| `TF_APPLY_FAILED`, `SSH_TIMEOUT`, `BOOT_FAILED`, `NO_CAPACITY`, `CREDENTIALS_FAILED` | infra | no |
| `TIMED_OUT_OR_CRASHED` | an engine run or the watchdog hit its time budget | possibly a krikri hang - read both `.out` tails |
| `STOPPED` | run was interrupted | no |
| `ERROR` | tool error | no - report to the user |

Results from tool < 0.3.1 (`versions.txt` says which) used the old, looser
`CLEAN`: it only meant the five recap counters matched, so two engines that
failed the same way, or printed different text, were `CLEAN`. For those, trust
the `bytes=` suffix over the status.

## 5. Skip what is byte-identical

A role with `bytes=IDENTICAL` matched on exit codes, per-task results and raw
output in both phases. **Do not read its logs.** Count it and move on. This is
the point of the byte comparison: it removes most roles from the LLM's
attention.

Everything else (`bytes=DIFFERENT`, or any status other than `CLEAN` and
`MATCHED_FAILURE`) needs a decision. A `MATCHED_FAILURE` is not krikri signal,
but list it for the user: the role is broken the same way on both engines.

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
- **Mask candidate (rare)** — a difference that can *never* be identical by
  nature: a timestamp, temp path, random ID, PID, or a probe-driven Ansible
  warning. Hold this to a high bar: if krikri could produce the same bytes with
  any amount of work, it is an output gap, not a mask candidate. Never propose a
  mask just to turn a role green. List candidates in the step 8 report with the
  exact diff hunk and why it is non-reproducible, and let the user decide;
  never edit `Compare::MASKS` yourself. A mask must be as narrow as possible
  (match only the varying part), and every one added should be rare enough that
  the list stays short.
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

Report before anything else happens — this is where the user's input is needed
(what is worth fixing now):

- What was tested (step 3) and the tally: `N identical / M different / K
  blocked`.
- Per root-cause group: one line of cause, the affected roles, one evidence
  path (`<dir>/<role>/compare_cold.diff`), and your classification.
- Mask candidates (step 7), if any: hunk, affected roles, why it can never be
  identical. Usually there are none; say so only if asked.
- Blocked/GALAXY_MISSING roles, listed, not analysed.

Then go to step 9. Do not start fixing: that is a separate skill.

## 9. Offer to file GitHub issues

After the step 8 report, offer to file one GitHub issue per confirmed root
cause (the real krikri bugs and output gaps - not infra, not
`COMMUNITY_MODULE_MISSING`, not `MATCHED_FAILURE`). Filing an issue publishes
text, so ask first; do not file them unprompted. The issues are the hand-off:
the `work-issues` skill reads them to decide what to fix.

Every issue filed with the `divergence` label must be actionable: one root
cause, one fix, a fenced repro. Never file status logs, coverage summaries,
"verified OK" lists, umbrella/`Tracking:` issues, deliberate limits or
anything with no single fix. That kind of note goes in `KNOWN_MISSING.md`
(or the round record in step 10), not in the issue tracker. If you cannot
write a repro for it, it is not an issue yet: say so in the report instead.

1. `gh issue list --label divergence --state all` in the krikri repo: if a
   root cause already has an issue, reuse it (comment with the new evidence)
   instead of filing a duplicate.
2. Show the user the proposed issues (title + one-line body) and ask which to
   file. Offer a clear "file all" / "file none" choice.
3. For each approved one: `gh issue create --label divergence --title ... --body ...`.
   The body must let someone with no access to this results directory start
   work, so it has: the cause, the affected roles (with the OS each ran on),
   a minimal repro or the exact diff hunk pasted in (inside a fenced code
   block: the fix tooling drops issues without one), the krikri commit and
   version from `versions.txt`, and the original evidence path
   (`<dir>/<role>/compare_cold.diff`) as a pointer only. Keep home-directory
   paths out of the body. Say whether it is a behavioural bug or an output gap.
4. Give the user the issue numbers and tell them to run `work-issues` when
   they want fixes started.

## 10. Record the round

Once triage is reported, update `ROLES_TESTED.md` in one commit: one row per
role tested - never bundled - each with cold/warm timing for both engines (from
the `report.txt` line). Every role from `queue.txt` gets a row, including ones
that stayed CLEAN, byte-identical or `MATCHED_FAILURE`. Skip timings from a
debug build. Only touch `KNOWN_MISSING.md` if a deliberate limit was decided.
No per-round narrative is written anywhere; `git log` is the record. Ask
before committing.
