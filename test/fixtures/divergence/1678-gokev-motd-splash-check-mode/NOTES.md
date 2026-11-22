# #1678 - gokev.motd-splash: the check run's equal-content template task

- Issue: https://github.com/weirdbricks/krikri/issues/1678
- Role: `gokev.motd-splash` (round `logs___1795231613`, check phase, ubuntu)
- Class: check-mode behavioural bug - exit code differs (ansible 2, krikri 0)

**What diverged.** The role's `motd template` task templates over an
existing `/etc/motd` (the warm run had left the rendered content there) with
`owner: root, group: wheel` on a host with no `wheel` group. On a checksum
match copy's action plugin hands the task to `ansible.legacy.file` instead
of the copy module, and that module's `set_group_if_different` still looks
the group name up under `--check` - so real ansible failed the task
(`chgrp failed: failed to look up group wheel`, after file.py's own "Create
group up to this point in real play" warning) and stopped the play. krikri
answered `ok`, then ran the role's next task (`issue template`) that ansible
never reached, which is why the block count and the PLAY RECAP differed too.

**Fixture.** The seed task reproduces the warm run's file without mutating
the machine (`check_mode: false` writes inside the scratch tree only). The
role's task keeps its parameters verbatim; only `src:`/`dest:` are pointed
into the scratch tree via `playbook_dir`, and `no_log: true` is added so
the recorded fatal result is censored - without it the transcript would
embed the destination's uid/gid/owner/group, which differ between this
box's user and the root CI container. The message and result shape are
pinned in-process by `test/integration/template_owner_group_test.cr` and
`test/integration/copy_attribute_reconcile_test.cr`.
