# #1677 - chkpnt.mailserver's zypper tasks are skipped in --check

- Issue: https://github.com/weirdbricks/krikri/issues/1677
- Role: `chkpnt.mailserver` (ubuntu host, round `logs___1795231613`)
- Class: check-mode behaviour (module execution, block count, exit code and recap)

**What diverged.** The role's `tasks/install.yml` writes the
`community.general.zypper_repository` and `community.general.zypper` FQCNs on
a host the role does not support (it is openSUSE-only). Under `--check`:

- `zypper_repository.py` declares `supports_check_mode=False`, so
  ansible-core's `basic.py` answers it with its own skip, which krikri printed
  identically - but the task was also registered for the end-of-run
  engine-limit exit 4 (`uses unimplemented plugin: ...`).
- `zypper.py` declares `supports_check_mode=True`, so real RUNS it, and
  `get_cmd()`'s `get_bin_path("zypper", required=True)` fatals the task with

```
Failed to find required executable "zypper" in paths: ...
```

krikri instead skipped the task, ran on through the role's `setup*.yml`
tasks, and stopped on `Enable server redis@rspamd and make sure it is
running` - a different transcript, block count, recap
(`ok=8 changed=3 skipped=2` vs `ok=2 changed=0 skipped=1`) and exit code
(4 vs real's 2).

**Fix.** `plugins/zypper.cr` and `plugins/zypper_repository.cr` implement the
AnsibleModule argument-validation surface plus the `get_bin_path("zypper")`
probe both modules run before any package/repository work (and the
check-mode skip for the module that declares no check-mode support), the
same minimal ported surface `plugins/pacman.cr` uses (issue #1583).
`zypper` and `zypper_repository` are registered in `AVAILABLE_PLUGINS`
(plus the `ansible.builtin.`/`ansible.legacy.` runtime redirects), so the
tasks run instead of being dropped as unavailable modules.

**Fixture.** The role's `tasks/`, `defaults/`, `handlers/`, `meta/` and
`filter_plugins/` are copied verbatim; only the play's host/connection are
adapted to localhost. `flags.txt` carries `--check`. `expected.out` was
captured from real ansible-core 2.21.6 (exit 2).
