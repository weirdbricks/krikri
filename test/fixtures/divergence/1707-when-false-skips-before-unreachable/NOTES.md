# #1707 - a `when:`-false task skips on a host the eager pass booked

- Issue: https://github.com/weirdbricks/krikri/issues/1707
- Repro: the issue's playbook verbatim. `always-fail` stands in for the dead
  ssh endpoint, so no real host is involved.

**What diverged.** ansible evaluates `when:` before it ever connects, so the
`ping:` prints `skipping: [target]` and the run never dials: recap
`ok=1 skipped=1 unreachable=0`, exit 0. krikri's eager pre-upload pass (set
off by the `ping:`) booked the host UNREACHABLE before any task ran, and the
pre-marked short circuit reported that under the `ping:` banner - a task
ansible skips - then halted the host, so the `debug:` never ran (recap
`ok=0 unreachable=1`, exit 4).

**Fix.** run_task_batch's short circuit asks whether the task may skip
before it ever connects (a `when:` evaluated through the executor's own
condition path) and, if so, hands the host to execute_task and releases the
booking the way a controller-side task does (#1706). The host is still lost
at the first task that really dials.
