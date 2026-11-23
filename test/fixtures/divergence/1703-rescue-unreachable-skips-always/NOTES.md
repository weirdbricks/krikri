# #1703 - a host lost in rescue: must not run always:

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: a body task that fails on its delegate (so `rescue:` is entered),
  a rescue task that dials the dead endpoint, and an `always:` section.
  `always-fail` stands in for the dead ssh endpoint.

**What diverged.** The rescue `ping:` loses the transport, which takes the
host out of the play: neither the `always:` section nor anything later runs,
recap `ok=0 rescued=1 unreachable=1`. krikri had already computed the unwind
host set from the body alone, so it re-entered `always:` and reported the
same UNREACHABLE again (`unreachable=2`).

**Fix.** `execute_block_multi` recomputes the unwind set before `always:`, so
a rescue-phase transport loss is excluded too, and the block tail force-halts
it.
