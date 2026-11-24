# 1775 - babisk.kubectl: the snap task is skipped in check mode where real runs it

- Issue: https://github.com/weirdbricks/krikri/issues/1775
- Role: `babisk.kubectl` (ubuntu host, round `logs___1795546590`, round29925792)
- Class: check-mode behavioural bug (task result and exit code differ)

**What diverged.** The role's `tasks/main.yml:10` task
`Install kubectl from snap` runs `community.general.snap` in `--check`.
Real ansible runs the module (answering `ok` for the already-installed
snap on the round's host) and exits 0; krikri skipped the task, printed
`Task 'Install kubectl from snap' uses unimplemented plugin:
community.general.snap` and exited 4.

**Why.** snap.py declares `supports_check_mode=True`, so real's
`--check` run executes the module: `get_bin_path("snap", required=True)`
inside `__init_module__` runs before any state's work (and before any
check-mode short-circuit), then `snap version` / `snap info` / `snap
list` decide present/absent. krikri had no snap plugin, so the task took
the graceful unavailable-module path (skip plus the exit-4
accounting).

**Fixture.** The role's snap task verbatim (params and tags included),
with `become: true` dropped so it runs as the local user. This box has
no snap CLI, so real's transcript here is the probe's
`Failed to find required executable "snap"` fatal - the same
ran-versus-skipped divergence the round hit, with the same root cause
(the module executes under `--check`).

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 13.2.0. `inventory.ini` pins the
interpreter on the `[local]` host.

**Fix.** `plugins/snap.cr` restores the native port registered as
`community.general.snap` (plus the `ansible.builtin.snap` /
`ansible.legacy.snap` redirects ansible-core's builtin runtime still
applies), so the module runs under `--check` and reports the same
ok/changed/failure as real instead of skipping the task.
