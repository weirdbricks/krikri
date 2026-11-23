# #1703 - a block's ignore_errors: must not un-halt a host lost in rescue:

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the rescue-unreachable shape with `ignore_errors: true` on the
  block; the body task overrides it to `false` (otherwise the inherited
  value swallows the failure and `rescue:` never runs). `always-fail` stands
  in for the dead ssh endpoint.

**What diverged.** The rescue `ping:` loses the transport, which takes the
host out of the play. `ignore_errors:` never covers that (only
`ignore_unreachable:` does), so neither `always:` nor anything later runs:
recap `ok=0 rescued=1 unreachable=1`. The block bookkeeping resolved
`ignore_errors` against the block task, un-halted the host and let the next
task report the same UNREACHABLE again.

**Fix.** The block tail force-halts any host whose own unreachable count rose
during the body or rescue, whatever the block's `ignore_errors:` says.
