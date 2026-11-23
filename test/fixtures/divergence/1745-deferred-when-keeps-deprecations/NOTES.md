# #1745 - a deferred `when:` keeps what its one evaluation produced

- Issue: https://github.com/weirdbricks/krikri/issues/1745
- Repro: a dead ssh endpoint (the always-fail stub) and a deferred `when:`
  reading the internal `vars` dictionary, with the skipped result registered.

**What diverged.** The probe's evaluation of the clause held its deprecation
block, and the second evaluation inside execute_task produced it again - so
the only block that reached the console and the registered result came from
the duplicate evaluation the fix removes.

**Fix.** The verdict carries the captured output, and when_passes? replays it
where the probe's own evaluation happened, so the block still prints under
the task banner and is still filed on the skipped register.
