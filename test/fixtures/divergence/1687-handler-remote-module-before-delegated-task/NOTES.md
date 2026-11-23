# #1687 - a handler's remote-only module must not pre-halt the host before a delegated task

- Issue: https://github.com/weirdbricks/krikri/issues/1687
- Repro: the issue's own playbook and inventory verbatim (paths adapted).
  `always-fail` stands in for the dead ssh endpoint (stderr detail + exit
  255), so no real host or port is involved.

**What diverged.** The play's only task delegates to `localhost`; its only
remote-only module sits in a handler. krikri's per-play pre-upload pass
walked the handlers too, tried to stage `ping` on `target` (whose
connection fails), and booked the host UNREACHABLE before any task ran - so
the `delegate_to: localhost` task itself reported
`fatal: [target]: UNREACHABLE!` and the handler never ran
(`ok=0 changed=0 unreachable=1`). ansible-core has no eager pass: it runs
the delegated task (`changed: [target -> localhost]`) and only dials
`target` when the handler's `ping` dispatches, so the handler is what
fails UNREACHABLE (`ok=1 changed=1 unreachable=1`, exit 4).

**Fix.** Two halves, one for each way the pre-pass leaked into the run:

1. `PluginManager.batch_upload_plugins_for_playbook` no longer collects the
   play's *handlers* into the eager plugin set. A handler-only module is
   uploaded lazily by the handler's own dispatch (every remote dispatch
   goes through `ensure_uploaded`), so the pass buys at most one round trip
   per module only a handler uses, and no longer dials a host whose every
   task delegates away.
2. `run_task_batch`'s pre-marked-unreachable short circuit now exempts a
   task carrying `delegate_to:`: the task executes on its delegate's
   connection, so the origin host's known unreachability is not reported
   under its banner. The host stays booked UNREACHABLE, so the first task
   (or handler) that really dials it fails there - ansible's shape.

`env.txt` pins `ANSIBLE_PIPELINING=False`: this box's shell exports
`ANSIBLE_PIPELINING=True`, which would switch both engines to the "Data
could not be sent to remote host" lead, and the harness passes the
environment through. The `target` interpreter pin keeps ansible's
interpreter discovery (a separate exec krikri does not model) from becoming
the host's first ssh usage.
