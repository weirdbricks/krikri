# #1706 - the eager booking is released, not just skipped

- Issue: https://github.com/weirdbricks/krikri/issues/1706
- Repro: the issue's playbook with its second task skipped, so ansible never
  dials at all. `always-fail` stands in for the dead ssh endpoint.

**What diverged.** ansible never opens the connection, so its recap is
`ok=1 skipped=1 unreachable=0` and the exit code is 0. krikri's eager
pre-upload pass dialed anyway and booked the host; exempting the `debug:` from
the short circuit alone would still leave the booking in place, so the skipped
`ping:` would report an UNREACHABLE ansible never reaches.

**Fix.** A controller-side task releases the booking the way
`ignore_unreachable:` already does (issue #1680): the host is back in the play
and only the first task that really dials loses it.
