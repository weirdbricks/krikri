# #1703 - a block's ignore_errors: must not un-halt a host the transport lost

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: an `ignore_errors: true` block whose only child dials the dead
  endpoint, then a controller-side task. `always-fail` stands in for the dead
  ssh endpoint.

**What diverged.** `ignore_errors:` covers failed tasks; the unreachable
counterpart is `ignore_unreachable:`. Once the body child lost the transport
the host is out of the play, so the following `debug:` task prints nothing.
krikri's block bookkeeping un-halted the host because the BLOCK carried
`ignore_errors: true` (the re-halt goes through the same resolve as a failed
task), so the next task's pre-marked-unreachable short circuit reported the
same UNREACHABLE a second time: `unreachable=2` where ansible recaps 1.

**Fix.** The block tail force-halts a host that became unreachable in the
body (or rescue:), whatever the block's own `ignore_errors:` says.
