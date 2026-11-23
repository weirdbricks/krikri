# #1745 - a deferred `when:` is evaluated once, not twice

- Issue: https://github.com/weirdbricks/krikri/issues/1745
- Repro: the issue's own shape - a dead ssh endpoint (the always-fail stub)
  and a `when:` whose side-effectful `lookup('pipe', ...)` appends a line to a
  counter file the second play reads.

**What diverged.** The eager pre-upload pass evaluated the clause to decide
whether the host really dials, and execute_task evaluated it again: the pipe
lookup ran twice where ansible runs it once.

**Fix.** The probe's verdict (and the output it produced) rides a per-(task,
host) value into when_passes?, which consumes it instead of re-evaluating the
clause.
