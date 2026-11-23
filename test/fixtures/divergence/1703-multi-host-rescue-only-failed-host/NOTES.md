# #1703 - rescue: serves the failed host only when another host is unreachable

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: a two-host play, one dead ssh endpoint and one local; the body
  child is a dialing task. The `copy:` failure is a stable stand-in (the
  `command:` module's failure JSON embeds start/delta timestamps).
  `always-fail` stands in for the dead ssh endpoint.

**What diverged.** The host the transport lost is out of the play; the other
host fails normally, so `rescue:` and `always:` run for it alone
(`ok: [good]`, `rescued=1`), while `target` recaps `unreachable=1`. The
unwind set is per host: `rescue_hosts` is the intersection of "still in the
play" and "failed here", not every host in the block.

**Fix.** `execute_block_multi` filters by each host's own unreachable-counter
delta, so only the failed host unwinds.
