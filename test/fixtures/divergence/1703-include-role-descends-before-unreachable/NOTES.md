# #1703 - include_role: hands the pre-upload UNREACHABLE down to the role's tasks

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's block: shape applied to the include_role: dispatch (same
  `run_task_batch` short circuit). `always-fail` stands in for the dead ssh
  endpoint; the trailing `ping:` is what makes the eager pass dial at all.

**What diverged.** krikri printed `TASK [include_role : kpgrole]` and booked
the pre-upload failure there, so the role never loaded: recap
`ok=0 changed=0 unreachable=1`. ansible announces the include
(`included: kpgrole for target`), runs the role's delegated child
(`TASK [kpgrole : command]` / `changed: [target -> localhost]`), and only
then fails at the task that dials: `TASK [ping]` +
`fatal: [target]: UNREACHABLE!`, recap `ok=2 changed=1 unreachable=1`.

**Fix.** `run_task_batch` exempts descending pseudo-tasks (`block:`,
`include_tasks:`, `include_role:`) from the pre-marked-unreachable short
circuit and hands the host to their children, which apply it themselves.
