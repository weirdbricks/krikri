# #1704 - `--force-handlers` must not flush a handler for an UNREACHABLE host

- Issue: https://github.com/weirdbricks/krikri/issues/1704
- Repro: the issue's own playbook, `--force-handlers` in flags.txt.
  `always-fail` stands in for the dead ssh endpoint (stderr detail +
  exit 255), so no real host or port is involved.
- Found while fixing #1687: before that fix the delegated task was itself
  swallowed by the pre-upload booking and never notified the handler, so
  this shape could not be reached from a play's first tasks.

**What diverged.** ansible's `force_handlers` lifts the halt for FAILED
hosts only. A host whose connection was lost is out of the play entirely,
so its notified handler never flushes even under the flag. krikri's
`run_handlers` passed `nil` (no skip set at all) when the flag was on, and
an unreachable host is booked into `@halted_hosts` too - so the handler
ran, dialled the dead endpoint a second time and recapped
`unreachable=2` with a second `[ERROR]`/`fatal` block. Real ansible
recaps `ok=1 changed=1 unreachable=1`, exit 4, with no handler banner.

`env.txt` pins `ANSIBLE_PIPELINING=False` for the reason #1687's case
gives (this box's shell exports `ANSIBLE_PIPELINING=True`, which switches
both engines to the "Data could not be sent to remote host" lead).

**Fix.** The unreachable hosts stay in the skip set whatever the flag
does: `@force_handlers ? @unreachable_hosts : (@halted_hosts |
@unreachable_hosts)`, so the flag only rescues failed hosts.
