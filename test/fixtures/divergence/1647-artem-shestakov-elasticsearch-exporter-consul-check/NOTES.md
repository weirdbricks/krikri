# artem_shestakov.elasticsearch_exporter: Register Consul service (check mode)

- issue: #1647
- role: artem_shestakov.elasticsearch_exporter (round `logs___1795172676/artem_shestakov_elasticsearch_exporter`)
- phase: check (`--check`, the round's block 13)
- task: `Register Elasticsearch service with the local consul agent`
- divergence: krikri's transcript carried one extra line after the recap,
  `uses unimplemented plugin: community.general.consul`, and the run exited 4
  where ansible exited 0. Every task line and the recap counters already
  matched.

## What diverged

The role's last task is `community.general.consul`. Its Ansible module creates
its `AnsibleModule` with `supports_check_mode=False`, so under `--check`
ansible-core's `basic.py` answers the task with a plain skip
(`remote module (community.general.consul) does not support check mode`, shown
only with `-v`) before the module body does anything - real never touched the
consul agent, and its exit code stayed 0.

krikri has no consul plugin, so the task took the unavailable-module skip,
which prints exactly the same `skipping:` line - but the skip also registered
the module in `reachable_unavailable_modules`, so the run ended with the
`uses unimplemented plugin` line and exit 4 for work real never did either.

The fix keeps that exit-4 accounting for unported modules that may well RUN
under `--check` in real (the triage signal from issue #1359), and drops it for
the ones whose Ansible implementation declares no check-mode support, where
real's check-mode transcript is the plain skip krikri already prints.

## Case adaptations

- `roles/artem_shestakov.elasticsearch_exporter/tasks/main.yml` is the role's
  `tasks/service_consul.yml` (the file its `main.yml` includes last) trimmed to
  the consul task, because the two tasks above it install python3 and
  python-consul on the machine. The role's `main.yml` tasks above that include
  (get_url/unarchive/copy/template/systemd) are dropped whole: real's
  `--check` run of them needs the tarball get_url would have fetched, which a
  localhost capture must not do. `defaults/main.yml` is verbatim.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 0). Re-capturing it needs a `community.general`
  the capture environment can resolve (the box that recorded it had the
  distro-shipped one visible): the module declares `supports_check_mode=False`
  in both the 11.x and 12.x releases, so any of them records the same skip line
  - the module's own "does not support check mode" message only shows with
  `-v`.
