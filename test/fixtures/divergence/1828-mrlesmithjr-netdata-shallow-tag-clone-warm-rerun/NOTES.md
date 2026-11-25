# #1828 - tobias_richter.netdata: the warm re-run dies in the git module

- Issue: https://github.com/weirdbricks/krikri/issues/1828
- Role: `tobias_richter.netdata` (galaxy), whose dependency
  `mrlesmithjr.netdata` runs the failing task, from round
  `logs___1795626220` / round29927209 (rocky, krikri 0.9.3119)
- Class: behavioural bug - a task ran on one side only (krikri `ok`,
  ansible failed)

## What diverged

`mrlesmithjr.netdata`'s `tasks/install.yml:6` clones netdata with
`depth: 1` and `version: v1.25.0`. That is `git clone --depth 1 --branch
<tag>`, so the checkout arrives with a detached HEAD and no
`refs/remotes/origin/HEAD`. Real's `git` module, on its next run over
that checkout, reaches `git.py:get_head_branch()`'s
`branch.startswith('-')` with `head_splitter()` having returned None (the
head ref file it falls back to under a detached HEAD does not exist) and
dies on the uncaught AttributeError - before the `fetch()` it was
computing a refspec for. krikri skipped the missing refspec and reported
`ok: Already up to date`, then carried on into the role's next tasks.

## Fix

`plugins/git.cr` mirrors that crash point: an unreadable head ref raises
`HeadBranchUnreadable` from `get_head_branch()` and the plugin reports
ansible-core 2.21's module-crash result instead of falling back to a nil
branch.

**Fixture.** The role's clone task verbatim (name, params, `depth:`,
`version:`), minus `become: true` - the failure precedes any privilege
escalation and the case runs as an ordinary user. It runs twice to stand
in for the round's cold clone and warm re-run. The role clones netdata's
real repository; a local fixture repo with the same shape (a tag off the
branch tip) keeps the case off the network. `expected.out` was captured
with `bin/krikri-capture-case` from real ansible-core 2.21.6.
