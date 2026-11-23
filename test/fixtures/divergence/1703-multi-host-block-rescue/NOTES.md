# #1703 - one unreachable host must not cancel another host's block

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: a two-host play (one dead ssh endpoint, one local) running the
  issue's block: shape with `rescue:`. `always-fail` stands in for the dead
  ssh endpoint; `good` is a local connection.

**What diverged.** Only the host the transport lost is out of the play; the
healthy host runs the body child (`changed: [good]`) and, not having failed,
never enters `rescue:`. krikri's block path must therefore filter the unwind
by host, not skip the section for everyone - the counters are per host and
`rescue_hosts` is the intersection of "still in the play" and "failed here".

**Fix.** `execute_block_multi`'s unwind set is per host (`unreachable_before`
delta), so the healthy host is untouched.
