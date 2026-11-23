# #1703 - a pre-upload UNREACHABLE is booked at the first child that dials, not at the block

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's own inventory and playbook verbatim (paths adapted).
  `always-fail` stands in for the dead ssh endpoint (stderr detail + exit
  255), so no real host or port is involved.

**What diverged.** The play's block has one child, a `command:`. krikri's
pre-marked-unreachable short circuit ran per TOP-LEVEL task, so the block
itself was booked and printed: `TASK [block]` plus an Origin pointing at the
block's own line (`playbook.yml:4:7`), recap `ok=0 changed=0 unreachable=1`.
ansible-core has no eager pass, so it runs the block and the failure is
booked at the first child that actually dials: `TASK [command]`, Origin
`playbook.yml:5:11`, same recap/exit code.

**Fix.** `run_task_batch` no longer applies the pre-marked-unreachable short
circuit to a task that only expands into other tasks (`block:`,
`include_tasks:`, `include_role:`) - those are handed down to their children,
each of which applies the same short circuit itself. A host that becomes
unreachable in a block body also skips the block's `rescue:`/`always:`, which
ansible never runs for a host it has dropped from the play.
