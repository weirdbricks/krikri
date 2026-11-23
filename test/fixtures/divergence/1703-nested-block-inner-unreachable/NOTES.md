# #1703 - a transport loss in a nested block unwinds neither level

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's block: shape wrapped in a second block, both carrying
  rescue:/always:. `always-fail` stands in for the dead ssh endpoint.

**What diverged.** The inner child loses the transport, which takes the host
out of the play: no rescue/always at either level runs after the child's
`fatal: [target]: UNREACHABLE!` (recap `unreachable=1`). krikri entered the
inner rescue (a second report) before the #1703 fix and would have entered
the outer sections as well.

**Fix.** Each `execute_block_multi` compares the host's own unreachable
counter against its own pre-body snapshot, so a booking raised by an inner
block is seen by the outer one too.
