# #1707 - an empty loop skips on a host the eager pass booked

- Issue: https://github.com/weirdbricks/krikri/issues/1707
- Repro: the issue's "empty loop" shape - the same play with `loop: []` on the
  remote task. `always-fail` stands in for the dead ssh endpoint.

**What diverged.** A loop source with no items means the task never runs, so
ansible prints `skipping: [target]` and never dials (recap
`ok=1 skipped=1 unreachable=0`, exit 0). krikri booked the pre-upload failure
and reported UNREACHABLE! at that task instead.

**Fix.** A looped task is handed to execute_task rather than booked: a loop
source must not be resolved twice (a lookup source would run twice) and a
`when:` over a loop is evaluated per item with that item bound. The zero-item
loop then prints its skip, and a loop that does dial books itself the moment
its own connection attempt fails - which is where ansible loses the host too.
