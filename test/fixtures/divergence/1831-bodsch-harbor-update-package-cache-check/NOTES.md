# 1831 - bodsch.harbor: check-mode "update package cache" reports ok, not changed

- Issue: https://github.com/weirdbricks/krikri/issues/1831
- Role: `bodsch.harbor` (ubuntu), round `round29927187`
- Evidence: `logs___1795626220/bodsch_harbor/compare_check.diff`

## What diverged

The role's `tasks/prepare.yaml` opens with

```yaml
- name: update package cache
  package:
    update_cache: true
```

In `--check` mode ansible-playbook reported `changed` for it and krikri `ok`
(the recap's `changed` counter differed by exactly one).

On Debian hosts `package:` delegates to apt.py, whose cache pass skips the
refresh itself under check mode (`if not module.check_mode:
cache.update()`) but still claims it once the refresh was due
(`if module.check_mode or updated_cache_time != post_cache_update_time:
updated_cache = True`), so a check-mode cache-only exit is always
`changed: true`. krikri's `package:` cache-refresh path ran the real
`apt-get update` under check mode as well - a persistent mutation on a run
that must not touch the target - and then decided `changed` from the lists
directory's mtime, which an all-Hit update leaves untouched. On the round's
host that produced `ok`.

## Case

`roles/bodsch.harbor/tasks/main.yml` is the role's `tasks/prepare.yaml` task
copied verbatim (the rest of the role installs docker and harbor, which needs
a real host); `playbook.yml` runs it against localhost in `--check` mode, as
the round did. `expected.out` is `bin/krikri-capture-case`'s capture from
ansible-core 2.21.6.

The in-process replay also covers the mutation half of the bug: the check
run happens as an unprivileged user, so a real `apt-get update` there fails
the task outright instead of reporting a change.
