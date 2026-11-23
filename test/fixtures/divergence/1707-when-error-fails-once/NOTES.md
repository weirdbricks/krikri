# #1707 - a raising `when:` fails the task once, not as UNREACHABLE

- Issue: https://github.com/weirdbricks/krikri/issues/1707
- Repro: the same play with a `when:` that cannot be evaluated.
  `always-fail` stands in for the dead ssh endpoint.

**What diverged.** ansible evaluates the condition before connecting, so an
undefined name fails the task: fatal FAILED (recap `failed=1`, exit 2) and
never an unreachable. krikri reported the booked UNREACHABLE! instead, so the
condition's own [ERROR] block was lost entirely.

**Fix.** The verdict is reached through the executor's own condition path, and
a raise there is swallowed: it is a task ansible fails before dialing, so the
host is handed to execute_task, which prints the failure exactly once (a probe
that reported it as well would print the error block twice).
