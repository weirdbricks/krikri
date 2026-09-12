---
name: fix-divergence
description: Investigate and fix a DIVERGENT role from a krikri-role-tester round using the Crush-delegated worktree workflow. Use whenever the user asks to "fix", "root-cause", "investigate", or "triage" one or more divergent roles from a completed batch round, or says "use crush" for this. Covers per-role worktree setup, delegating to Crush, independent validation before merge, and landing the fix. Launching the batch itself is a separate skill (`launch-roles`); this one starts after a round is DONE.
---

# Fix a divergent role (Crush worktree workflow)

This is steps 3-5 ("Triage" / "Fix phase" / "Confirm phase") of the
real-host benchmark-round workflow in
`/home/labros/git_work/krikri/CLAUDE.md` — read that section first. One
invocation of this skill handles ONE divergent role. For N divergent roles,
run N of these — capped at 2 concurrently (see step 2).

## 0. Don't skip triage

Before treating a DIVERGENT role as a bug to fix: dedupe by root cause (two
roles hitting the same missing module is one fix, not two), and separate
"genuinely unimplemented module" / "broken upstream role" / "shared
external-service-unreachable" from an actual behavioral difference between
the two engines. Plenty of "bugs" turn out to be one of the first three —
CLAUDE.md says so explicitly. If a fork/subagent already did this triage
pass and handed you a specific role + evidence path, skip straight to step 1.

## 1. Set up an isolated worktree

```bash
cd /home/labros/git_work/krikri
git worktree add -q /home/labros/git_work/krikri-worktrees/mismatch-<role-slug> \
  -b crush/mismatch-<role-slug> main
```

Branch from **current** `main`, not a stale commit — if you're about to
launch several of these worktrees at once and only get around to some later,
re-run `git worktree add` fresh off `main` right before you actually start
work on each one (or `git rebase main` inside it first) rather than trusting
a worktree created hours earlier.

## 2. Delegate to Crush — max 2 concurrent, always

**Never run more than 2 concurrent `mcp__crush-api__crush_run` calls against
this repo**, even across separate worktrees — 15 parallel crashed the user's
desktop once (memory: `crush-concurrency-limit`). If you're fixing several
roles, either process 2 at a time yourself, or spawn exactly 2
general-purpose subagents at a time (each owning one role end-to-end
including its own `crush_run` call), wait for both, then launch the next 2.

Each subagent's prompt needs, self-contained (subagents start with zero
context):
- The worktree path and branch name.
- The role name, its `~/scratch/krt-results/<round>_<backend>_<role>/`
  evidence directory, and what files there to read (`run.log`,
  `summary.txt`, `cold_py.out`/`cold_crystal.out`/`warm_py.out`/
  `warm_crystal.out`, `galaxy_install.log`).
- Instructions to fetch the real role source
  (`ansible-galaxy role install <role> -p /tmp/galaxy-roles`) and build a
  MINIMAL local repro (`ansible_connection=local`/`localhost`, no live VM
  needed) comparing real `ansible-playbook` against a freshly-built
  `bin/krikri-playbook`.
- **Explicit warning that Crush has previously dropped a `return` keyword**
  mid-fix, breaking control flow in a way that still happened to compile —
  tell the subagent to read Crush's diff line by line, not just trust that
  it builds.
- This repo's comment convention: explain WHY (real Ansible's behavior, the
  round that found it), never WHAT the code does.
- Explicit instruction: **do not merge to main** — push the branch and stop.

## 3. Validate independently before trusting anything — every time, no exceptions

Do this yourself even after a subagent reports "landed" and claims it
validated — subagents drop steps, and this repo has a strong bias toward
double-checking rather than trusting a transcript. If a "SECURITY WARNING"
flag comes back on a task notification, check it BEFORE reading the rest of
the report — usually `git log` on `main` (confirm nothing merged without
you) plus a scan of `/tmp`/home for out-of-place files is enough to clear it
as a benign false positive (e.g. a legitimate stdio/fcntl workaround for
this sandbox's non-blocking-IO issue with `ansible-playbook`), but never
skip the check.

1. **Rebase onto current `main` first**, since a sibling fix may have merged
   while this worktree sat: `git rebase main`. If `src/krikri/version.cr`
   conflicts, take `main`'s value and bump one more (see step 5) — don't
   just pick one side blindly.
2. `git diff main --stat` then **read the actual diff**, not just the stat —
   check for a dropped `return`, a wrong variable name, or logic that
   doesn't match the stated root cause.
3. `./build.sh` must build clean.
4. `crystal spec` (full suite, not just the new spec file) — the ONLY known
   pre-existing failure is `spec/integration/cli_spec.cr:1246` (needs a real
   Docker/Podman daemon). Anything else failing is real; don't land it.
5. `ameba` on the changed files — copy the binary in if the worktree doesn't
   have one (`cp /home/labros/git_work/krikri/bin/ameba <worktree>/bin/ameba`).
   A finding on a changed line is real; a finding on an unrelated
   pre-existing line (check by running `ameba` on that same file on `main`)
   is not your problem.
6. **Re-run the repro yourself**, and where practical, diff it directly
   against real `ansible-playbook`'s own output/recap — not just "looks
   plausible." Real `ansible-playbook` needs a pty to avoid this sandbox's
   non-blocking-stdio error: `script -qec "ansible-playbook ..." /dev/null`.

## 4. Commit — the `--amend` trap

**`git add -A` before every `git commit --amend`.** Editing a file (e.g.
bumping `VERSION` after a rebase) and then amending without staging first
silently drops that edit from the commit — happened twice in one session.
After any amend, verify with `git show HEAD:src/krikri/version.cr` (or
whatever file you just edited) that the committed content actually matches
what's on disk, not just what you intended.

Version bump: read `src/krikri/version.cr` fresh (after the rebase in step
3.1) rather than assuming a number — a sibling fix may have already taken
the "next" version.

Push: `git push -u origin crush/mismatch-<role-slug>` (or
`--force-with-lease` if amending after an earlier push, e.g. post-rebase).

## 5. Merge to main (this is on you, not the subagent)

```bash
cd /home/labros/git_work/krikri
git fetch origin --quiet
git merge --no-ff origin/crush/mismatch-<role-slug> -m "Merge crush/mismatch-<role-slug>: <summary>, <version>

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: <this session's URL>"
git push
```

Then clean up: `git worktree remove <path> --force`,
`git branch -d crush/mismatch-<role-slug>`,
`git push origin --delete crush/mismatch-<role-slug>`.

## 6. Documentation (batch this, don't do it per-role)

Once ALL roles from a round's triage are either fixed or dispositioned
(missing module / broken upstream / not-yet-root-caused), update
`KNOWN_MISSING.md` and `ROLES_TESTED.md` together in one commit — not one
commit per role. See CLAUDE.md's own note on this: `ROLES_TESTED.md`'s
row for an already-documented divergent role updates from "not yet
root-caused" to the actual root cause + fix version, and
`KNOWN_MISSING.md` gets a summary narrative with the closed open-gap
entries removed. Bump the README version badge in the same commit.
