# #1706 - set_fact:, assert: and include_vars: all run before the loss

- Issue: https://github.com/weirdbricks/krikri/issues/1706
- Repro: the module class the issue names, in one play, with the `ping:` that
  makes the eager pre-upload pass dial. `always-fail` stands in for the dead
  ssh endpoint.

**What diverged.** krikri reported the UNREACHABLE! at the first
`set_fact:` and never ran the controller-side tasks ansible runs.

**Fix.** Same classification as the `debug:` case: the short circuit exempts
every module that never opens the host's connection. `fetch:`,
`wait_for_connection:`, `synchronize:` and `reboot:` stay out of the set -
they execute from the controller but each dials the target itself.
