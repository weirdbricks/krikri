---
name: work-issues
description: Decide what to fix next from krikri's GitHub issues and drive the fixes. Reads the open `divergence` issues (filed by the `launch-roles` triage skill), drops tracking/blocked/already-in-flight ones, proposes a ranked work list, then runs each chosen issue through `fix-divergence` (worktree, Crush, validation, merge, `Fixes #N`) and asks the user to re-run the affected roles to confirm. Use whenever the user asks to "work the issues", "fix the divergences", "pick what to fix", "what should we work on", or says "use crush" without naming a specific role. Does not triage results directories (that is `launch-roles`).
---

# Work krikri's divergence issues

The input is GitHub, not a results directory. Triage already happened in
`launch-roles`, which files one issue per root cause. This skill reads those
issues, decides what is worth doing now, and hands each one to
`fix-divergence` for the mechanics. Read `fix-divergence` before step 3.

**The user runs `krikri-role-tester` themselves; never start it.**

## 1. Read the issues

```bash
cd /home/labros/git_work/krikri
gh issue list --label divergence --state open --limit 100 \
  --json number,title,labels,assignees,updatedAt,comments
gh issue view <N> --comments        # for each candidate
```

## 2. Decide what to work on

Drop, and say why in one line each:

- **Tracking / umbrella issues** (title starts `Tracking:`, or no single fix).
- **Blocked or declined**: labels `wontfix`, `question`, `invalid`, or a
  comment saying it waits on something.
- **Already in flight**: an open PR (`gh pr list --state open`), a
  `crush/*` remote branch (`git branch -r | grep crush/`), or a worktree under
  `/home/labros/git_work/krikri-worktrees/`.
- **Not reproducible from the issue alone**: no pasted repro or diff hunk, and
  its evidence path no longer exists. Ask the user for the results directory,
  or leave it.

Rank what is left:

1. Behavioural bugs (different exit code, task result, skipped/run on one side
   only) before output-text gaps.
2. Within each, wider blast radius first: a cause that touches every failing
   role (error ordering, error rendering) before one tied to a single module.
3. Cheap and well-specified before open-ended.

Group issues that share code (the same renderer, the same plugin) so they are
fixed together or in sequence, never in two concurrent worktrees: concurrent
edits to the same evaluator/plugin code are not safe.

Present the ranked list to the user: issue number, title, class, one-line
reason it is where it is, and what was dropped. Then ask which to start,
unless they already said "all". Never start more than 2 Crush jobs at once.

## 3. Fix each chosen issue

For each issue, follow `fix-divergence` end to end (worktree off current
`main`, confirm the root cause yourself with a minimal repro against
`ansible-playbook`, tight prompt to Crush, read the diff line by line,
`./build.sh`, full `scripts/minitest.sh -- -p 4`, `ameba`, merge). Add to what
that skill says:

- Name the issue in the Crush prompt and put `Fixes #N` in the commit message
  so the merge closes it.
- If the issue's cause turns out wrong or already fixed, comment on the issue
  with what you found instead of silently dropping it, and tell the user.
- A new root cause found on the way gets its own issue (ask first, as in
  `launch-roles` step 9); do not widen the current fix.
- Validate and merge one at a time (version bumps collide otherwise).

## 4. Confirm with a re-run - by the user

Passing the suite proves no regression, not that the divergence is gone.
After a fix lands on `main`:

1. Tell the user to rebuild (`./build.sh --release`); the run only tests what
   is in the binary, and `versions.txt` of the next run shows the commit.
2. Write a queue file with only the affected roles (copy their lines, with the
   OS, from the old `queue.txt`; the issue lists the roles and OS):

   ```
   hoplacloud.fail2ban any rocky
   ```

3. Give the user the command and ask them to send back the new directory:

   ```
   ./bin/krikri-role-tester --auto-mode --queue <queue-file>
   ```

4. Triage that directory with `launch-roles`. The role must come back
   `CLEAN` / `bytes=IDENTICAL`, or, if a remaining difference is a known,
   accepted output gap, the user says so explicitly. Otherwise comment on the
   issue (it stays open) and treat it as a new investigation.

Do this per fix as it lands, not batched at the end.

## 5. Close out

When a fix is confirmed: check the issue closed (`gh issue view <N>`); if
`Fixes #N` did not close it, close it with a comment naming the commit and
version. Update `ROLES_TESTED.md` rows for the affected roles and bump the
`README.md` version badge to the final `VERSION` reached, in one commit for
the batch, not per issue.
