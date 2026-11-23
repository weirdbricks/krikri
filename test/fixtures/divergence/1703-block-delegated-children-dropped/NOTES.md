# #1703 - a fully delegated block must run before the host is lost

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's second playbook verbatim (paths adapted, plus the
  handler its block-level `notify:` names). `always-fail` stands in for the
  dead ssh endpoint, so no real host is involved.

**What diverged.** The block's only child delegates to `localhost`, and the
task after it really dials the dead host (which is what makes the eager
pre-upload pass dial at all). ansible runs the block's child
(`changed: [target -> localhost]`) and loses the host at the second task:
`TASK [command]` + `fatal: [target]: UNREACHABLE!`, recap
`ok=1 changed=1 unreachable=1`. krikri booked the pre-upload failure at the
block, dropped the delegated child entirely and reported the block itself,
recap `ok=0 changed=0 unreachable=1` - the same short-circuit bug as the plain
block case, with the task-result difference as its worse effect.

**Fix.** Same as the plain block case: the descending task (`block:`) is not
the one that dials, so the host is handed to its children and the child owning
a `delegate_to:` runs on its delegate's connection (issue #1687's exemption).
