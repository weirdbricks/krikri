# #1703 - include_tasks: books the UNREACHABLE at the included dialing child

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the include_tasks: shape with a plain (non-delegating) child, plus a
  trailing `ping:` (what makes the eager pass dial at all). `always-fail`
  stands in for the dead ssh endpoint.

**What diverged.** krikri booked the pre-upload failure at
`TASK [include_tasks]` and never loaded the included file. ansible runs the
include (`included: <WORK>/tasks/inner.yml for target`) and fails at the
included task itself (`TASK [command]`, Origin
`<WORK>/tasks/inner.yml:1:3`), recap `ok=1 unreachable=1`.

**Fix.** `run_task_batch` hands a descending task's host to its children, so
the included file loads and its own child applies the short circuit.
