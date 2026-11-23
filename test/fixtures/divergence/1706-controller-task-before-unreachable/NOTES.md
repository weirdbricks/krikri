# #1706 - a controller-side task runs before the host is lost

- Issue: https://github.com/weirdbricks/krikri/issues/1706
- Repro: the issue's playbook verbatim. `always-fail` stands in for the dead
  ssh endpoint, so no real host is involved.

**What diverged.** `debug:` runs on the controller and never uses the host's
connection. The eager pre-upload pass (triggered by the `ping:`) booked the
host UNREACHABLE before any task ran, and krikri's pre-marked short circuit
reported it under the `debug:` task's banner: cap `ok=0`, the fatal's Origin
pointing at the debug. ansible has no eager pass, so it runs the debug and
loses the host at the ping: `ok=1 unreachable=1`, same exit 4.

**Fix.** run_task_batch's short circuit exempts tasks whose module never
opens the connection (debug:, assert:, fail:, set_fact:, pause:, add_host:,
group_by:, set_stats:, meta:, include_vars:,
validate_argument_spec:) exactly the way it already exempted `delegate_to:`
(#1687) and descending wrappers (#1703).
