# jgkim.dotfiles: Ensure the dotfiles repository is cloned locally.

- issue: https://github.com/weirdbricks/krikri/issues/1764
- role: jgkim.dotfiles
- round dir: `logs___1795546590/jgkim_dotfiles` (phase: cold, block 4)
- task: Ensure the dotfiles repository is cloned locally.

## What diverged

The round's host had no `git`, so the role's first task failed with
`Failed to find required executable "git" in paths: ...`. Real Ansible stopped
there. krikri also printed a second `[ERROR]` chain - for the role's NEXT task,
whose `changed_when: "return_value.stdout.find('up to date') == -1"` raised
against a controller-side preparation failure:

```
[ERROR]: Task failed: Module failed: A 'changed_when' expression failed: ...
Origin: <WORK>/roles/jgkim.dotfiles/tasks/main.yml:8:3
```

A batch group prepares every member before any of their banners' results
display, and a member an earlier failure halts the play before is never reached
at all - so that block must be stashed on the result and printed only under the
member's own banner (see `src/krikri/task_executor/executor_run_loop.cr`'s
`apply_batch_build_changed_failed_when`).

## Corpus fit

`playbook.yml` runs the role as the round did; `env.txt` takes git off `PATH`
(`/nonexistent` plus the sbin dirs), reproducing the round host's missing git
so the failing task is the real one, verbatim. `expected.out` is real
ansible-core 2.21.6's transcript for that play.

The extra chain itself only exists on the batching path, which requires a
non-local connection, so it cannot be replayed in-process. It is pinned by
`test/integration/batch_later_member_changed_when_error_test.cr` (sshd-gated,
skips without one), which fails before the fix for both orderings: a later
member's chain printed early, and printed at all when the earlier member's
failure halts the play before it.
