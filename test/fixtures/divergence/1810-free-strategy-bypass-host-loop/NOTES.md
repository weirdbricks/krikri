# 1810 - free strategy refuses a bypass-host-loop task

- Issue: https://github.com/weirdbricks/krikri/issues/1810
- Playbook: `000030-multi-package_facts-happy` (krikri-playbook-generator,
  seed 1795610889), plays `multi-task #30.0` / `#30.1`.

## What diverged

Both engines printed play #30.0 identically, then printed the `PLAY
[... #30.1]` banner. Real ansible stopped right there: its
`free`/`host_pinned` strategy loop raises as it DEQUEUES a task whose
action plugin declares `BYPASS_HOST_LOOP` (`pause`, `add_host`), because
such a task bypasses the per-host loop and would instead run once for
every host in the inventory. It is a strategy-level error, so the run
ends with the `[ERROR]` line plus the task's Origin block on stderr, no
`TASK [...]` banner, no PLAY RECAP and rc=1. krikri printed the pause's
console lines, ran the rest of play #30.1 and the plays after it, and
recapped normally.

The raise happens at dequeue time, before the task's own `when:`/
`ignore_errors:`/check-mode handling, which is why the play's
`when: kpg_task_0 is not skipped` does not shield it.

## What this case pins

The issue's two plays with their `strategy: free` and the failing
`Pause #30.1` task YAML copied verbatim, adapted to run against
localhost: the play targets `target` and delegates to `target2`, so both
are pinned (with the interpreter) in the case's own inventory, and play
#30.1's tasks AFTER the pause are dropped - real never reaches them, and
they only exist on the round's fixture host (the `retry.sh` script, the
`kpgrole` role and the `kpg_list` lookup under `/opt/kpg-fixtures`).
Play #30.0 keeps `package_facts:` under `--check`, so nothing on the
machine is mutated.

Real's transcript ends at the Origin block; a regression that lets the
run continue adds output, which the corpus replay fails on exactly like
missing output.
