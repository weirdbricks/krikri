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

## 2. Delegate to Crush — YOU call it directly, max 2 concurrent

**Call `mcp__crush-api__crush_run` yourself, from the orchestrator's own
context — do not wrap it in a Claude subagent.** A Claude general-purpose
subagent whose main job is "investigate, call Crush, validate" costs Claude
tokens twice over: once for the subagent's own investigation/validation,
and again when the orchestrator re-does that same validation before merging
(step 3 says to do this unconditionally, subagent report or not - so the
subagent's version of that work is pure waste). Crush is the cheap part;
don't spend expensive Claude turns re-deriving what Crush already did once
you're going to redo the checking yourself anyway. Do the investigation
(fetch the real role, build the minimal repro, compare against real
`ansible-playbook`) yourself, hand Crush a tight prompt for just the code
change once you know the root cause, then run the full validation in
step 3 yourself - one continuous flow, not a spawn-and-re-check round trip.

**Never run more than 2 concurrent `mcp__crush-api__crush_run` calls against
this repo**, even across separate worktrees — 15 parallel crashed the user's
desktop once (memory: `crush-concurrency-limit`). Since you're calling Crush
directly now instead of through subagents, this means: work on 2 roles'
worktrees interleaved in your own turns (dispatch a `crush_run` for role A,
while it runs dispatch one for role B, then come back to review both diffs)
rather than firing off 2 parallel Claude subagents.

Only reach for a real subagent (not a Crush-wrapping one) when the
investigation itself is the expensive part and genuinely benefits from
running unsupervised in parallel with other orchestrator work - e.g. a
round with many roles queued and you want triage/investigation on several
happening at once before you get to the fix step. Even then, have it stop
at "root cause confirmed, here's the prompt for Crush" and do the actual
`crush_run` + validation yourself.

Your prompt to Crush needs, self-contained:
- The exact root cause you've confirmed (not a hypothesis - confirm it
  yourself against real `ansible-playbook` first, per the repro workflow
  below, before ever calling Crush).
- The worktree path and file(s) to change.
- **Explicit warning that Crush has previously dropped a `return` keyword**
  mid-fix, breaking control flow in a way that still happened to compile —
  you MUST read Crush's diff line by line yourself afterward, not just
  trust that it builds.
- This repo's comment convention: explain WHY (real Ansible's behavior, the
  round that found it), never WHAT the code does.
- Explicit instruction: **do not touch `src/krikri/version.cr`**. Version
  bumps happen once, centrally, at merge time (step 5) - if you're working
  2 roles interleaved, both worktrees start from the same `main`, so
  bumping early in either one just produces a collision to untangle later
  for no benefit (nothing in the spec suite checks the number itself, only
  that `RUNTIME_DEPENDENCY_FORK_NOTES` matches `shard.yml`'s tags - the
  bump is pure traceability).

To fetch the real role source and build the minimal repro yourself before
calling Crush: `ansible-galaxy role install <role> -p /tmp/galaxy-roles`,
then a small `ansible_connection=local`/`localhost` playbook (no live VM
needed) comparing real `ansible-playbook` against a freshly-built
`bin/krikri-playbook`. The evidence directory for the original divergence
is `~/scratch/krt-results/<round>_<backend>_<role>/` (`run.log`,
`summary.txt`, `cold_py.out`/`cold_crystal.out`/`warm_py.out`/
`warm_crystal.out`, `galaxy_install.log`).

## 3. Validate before trusting anything — every time, no exceptions

This is the same continuous flow as step 2 when you called Crush yourself -
just keep going. If a triage subagent handed off "root cause confirmed" and
you called Crush from a fresh context picking that up, or a subagent DID
end up owning a `crush_run` call (the exception case in step 2), redo this
validation from scratch regardless of what it reported — don't trust a
transcript. If a "SECURITY WARNING"
flag comes back on a task notification, check it BEFORE reading the rest of
the report — usually `git log` on `main` (confirm nothing merged without
you) plus a scan of `/tmp`/home for out-of-place files is enough to clear it
as a benign false positive (e.g. a legitimate stdio/fcntl workaround for
this sandbox's non-blocking-IO issue with `ansible-playbook`), but never
skip the check.

1. **Rebase onto current `main` first**, since a sibling fix may have merged
   while this worktree sat: `git rebase main`. The subagent never touched
   `src/krikri/version.cr` (see step 2), so this shouldn't conflict; if it
   somehow does, take `main`'s value — the actual bump still happens only
   at step 5, on `main`, right before merging.
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

No version bump at this stage — the subagent's commit doesn't touch
`src/krikri/version.cr` at all (see step 2). That happens once, centrally,
in step 5, right before merging.

Push: `git push -u origin crush/mismatch-<role-slug>` (or
`--force-with-lease` if amending after an earlier push, e.g. post-rebase).

## 5. Merge to main (this is on you, not the subagent)

Bump the version FIRST, directly on `main`, immediately before merging —
this is the only place `src/krikri/version.cr` gets touched, so there is
never a collision to untangle:

```bash
cd /home/labros/git_work/krikri
git fetch origin --quiet
# read src/krikri/version.cr fresh, bump one past it, commit that alone
git commit -am "Bump version to <next>" # or fold into the merge commit below
git merge --no-ff origin/crush/mismatch-<role-slug> -m "Merge crush/mismatch-<role-slug>: <summary>, <version>

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: <this session's URL>"
git push
```

If two fixes finish close together, whichever you merge first gets the
next number; re-read `version.cr` before bumping for the second.

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
