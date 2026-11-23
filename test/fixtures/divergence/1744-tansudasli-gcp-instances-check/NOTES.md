# tansudasli.gcp_instances: GCP instance tasks (check mode)

- issue: #1744
- role: tansudasli.gcp_instances (round `logs___1795423891/tansudasli_gcp_instances`)
- phase: check (`--check`, the round's block 8)
- tasks: `create boot-disk`, `create non-boot-disks`, `create a static-IP
  address`, `create an instance`
- divergence: krikri's transcript carried four extra lines after the recap,
  one `uses unimplemented plugin` line per GCP module, and the run exited 4
  where ansible exited 0. Every task line and the recap counters
  (`ok=1 ... skipped=4`) already matched.

## What diverged

Every module of the google.cloud collection is generated from `GcpModule`,
which does not pass `supports_check_mode` to `AnsibleModule` - only the
read-only `_info` readers opt in with `supports_check_mode=True`. Under
`--check`, ansible-core's `basic.py` therefore answers each of these mutating
tasks with a plain skip (`remote module (gcp_compute_disk) does not support
check mode`, shown only with `-v`) before the module body does anything. Real
did no work for any of the four tasks and kept exit 0.

krikri ports no google.cloud module, so the tasks took the unavailable-module
skip, which prints exactly the same `skipping:` lines - but the skip also
registered each module in `reachable_unavailable_modules`, so the run ended
with the four `uses unimplemented plugin` lines and exit 4 for work real never
did either.

The fix extends the #1647 check-mode exception from its single explicit
`consul` name to the whole google.cloud family: a `gcp_*` module that is not
one of the `_info`/`_facts` readers is registered nowhere under `--check`,
because real skips it there. Outside `--check` the exit-4 accounting is
unchanged, and so is it for the `_info` readers, which real really runs.

## Case adaptations

- `playbook.yml` is the play krikri-role-tester generates for the role; only
  the local connection differs (the round's testhost was reached over ssh and
  ran the role as root, which a localhost capture cannot sudo - none of the
  GCP tasks needs root, and all of them are skipped anyway).
- `roles/tansudasli.gcp_instances/` carries the role's `tasks/main.yml` and
  `defaults/main.yml` verbatim.
- `env.txt` disables deprecation warnings. google.cloud's module payloads
  import `to_text` from the deprecated `ansible.module_utils._text` shim, so
  real prints its one-time hint plus a `[DEPRECATION WARNING]`; krikri models
  those lines from payload sources baked into `collection_runtime_data.cr`,
  which does not carry google.cloud (the round's compare masks warning text,
  and this issue is the exit code plus the `uses unimplemented plugin` lines).
  Same mechanism as case 1660, which pins this setting itself.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 0). Recapturing it needs a google.cloud the
  capture environment can resolve; every 1.x release generates its mutating
  modules the same way, so the skip lines are the same.
