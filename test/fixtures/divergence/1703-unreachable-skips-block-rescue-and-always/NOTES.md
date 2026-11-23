# #1703 - a host lost inside a block runs neither rescue: nor always:

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's block: shape with both unwind sections attached.
  `always-fail` stands in for the dead ssh endpoint, so no real host is
  involved.

**What diverged.** The block body's only child dials the dead host, so the
host is lost at the transport. ansible removes it from the play right there:
neither `rescue:` nor `always:` runs, and the block's only report is the
child's own `TASK [command]` + `fatal: [target]: UNREACHABLE!` (recap
`unreachable=1`). krikri, once the block descends into its child (the #1703
fix), treated the halted host as a FAILED one, entered `rescue:` and printed
a SECOND unreachable at the rescue task's banner (`unreachable=2`).

**Fix.** `execute_block_multi` unwinds only the hosts that did not become
unreachable in the body: an unreachable host is out of the play, so
`rescue:`/`always:` skip it. The test is the host's own unreachable count
going up during the body, not mere membership in the known-unreachable set:
a host the eager pre-upload pass booked but whose body only delegated never
lost its connection, and still unwinds normally.
