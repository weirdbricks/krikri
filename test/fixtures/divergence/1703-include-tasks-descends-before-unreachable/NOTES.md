# #1703 - include_tasks: hands the pre-upload UNREACHABLE down to its children

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's block: shape applied to the include_tasks: dispatch
  (same `run_task_batch` short circuit). `always-fail` stands in for the dead
  ssh endpoint; the trailing `ping:` is not invented - without a task that
  really connects the eager pass uploads nothing and never dials.

**What diverged.** krikri printed `TASK [include_tasks]` and booked the
pre-upload failure there, so the included file never loaded: recap
`ok=0 changed=0 unreachable=1`. ansible runs the include (its own `ok`, the
`included:` line), runs the included delegated child
(`changed: [target -> localhost]`), and only then fails at the task that
dials: `TASK [ping]` + `fatal: [target]: UNREACHABLE!`, recap
`ok=2 changed=1 unreachable=1`.

**Fix.** `run_task_batch` exempts descending pseudo-tasks (`block:`,
`include_tasks:`, `include_role:`) from the pre-marked-unreachable short
circuit and hands the host to their children, which apply it themselves.
