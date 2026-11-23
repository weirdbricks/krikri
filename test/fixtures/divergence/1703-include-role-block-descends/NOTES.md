# #1703 - a role's own block: follows the same descend-and-unwind rules

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: an `include_role:` whose role wraps a dialing child in a block with
  both unwind sections, plus a trailing `ping:` (what makes the eager pass
  dial at all). `always-fail` stands in for the dead ssh endpoint.

**What diverged.** A role's task list runs one host at a time through the
single-host block path (`execute_task` -> `execute_block`), which had none of
the #1703 rules: the child's transport loss entered `rescue:` and `always:`
(the two debug tasks ran, `ok=3`) and un-halted the host, so the trailing
`ping:` was reported as well - `unreachable=2` where ansible recaps 1 and
runs nothing after the fatal.

**Fix.** `execute_block` takes the same unreachable snapshot, skips
`rescue:`/`always:` for a host that lost the transport in the body or
rescue, and force-halts it.
