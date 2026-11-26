# billyrayvalentine.susefirewall: zypper install in check mode

- issue: #1850 (https://github.com/weirdbricks/krikri/issues/1850)
- role: billyrayvalentine.susefirewall (rocky, round `logs___1795686235/billyrayvalentine_susefirewall`)
- phase: check (`--check`, the round's `compare_check.diff`)
- task: `roles/billyrayvalentine.susefirewall/tasks/main.yml:2` (`Install SuSEfirewall2 rpm`)
- divergence: task results differ: ansible=[fatal] krikri=[skipping], recap `skipped=0`
  vs `skipped=1`, exit codes 2 vs 4.

## What diverged

The role's first task is a plain `zypper:` install. community.general.zypper
declares `supports_check_mode=True`, so under `--check` real ansible executes
it; its command builder runs `get_bin_path("zypper", required=True)` before
any package work, which fails on a host without the SUSE package manager:

```
fatal: [testhost]: FAILED! => {"changed": false, "msg": "Failed to find required executable \"zypper\" in paths: ..."}
```

That ends the play (real exit 2). krikri had no `zypper` plugin, so the task
took the unavailable-module skip - `skipping:`, recap `skipped=1`, exit 4 with
`Task 'Install SuSEfirewall2 rpm' uses unimplemented plugin: zypper` - and the
play carried on to the next task (`service:`), which failed on its own.

## Fix

`plugins/zypper.cr` is a probe-only port, the same shape as
`podman_container` (issue #1156): the AnsibleModule argument validation and
the `get_bin_path("zypper", required=True)` probe, plus main()'s branches that
decide whether the probe runs at all. Everything after a successful probe is
unported (see KNOWN_MISSING.md) - SUSE is outside this engine's Ubuntu/RHEL
target range, and the probe failure is the whole observable surface there.

## Case adaptations

- `playbook.yml` is the play krikri-role-tester generates, only adapted to
  localhost (`gather_facts: false`, since the failing task needs no facts and
  the 2.21.6 Gathering Facts block is a separate divergence).
- `roles/billyrayvalentine.susefirewall/tasks/main.yml` is the role's task
  file verbatim; only the first task is reached.
- `inventory.ini` pins the interpreter on the `[local]` host, the placement
  both engines read alike.
- `expected.out` is a real ansible-core 2.21.6 capture
  (`bin/krikri-capture-case`, exit 2). The message names the PATH searched,
  and the capture tool pins that to the standard system directories, so the
  recording is machine-independent.
