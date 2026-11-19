# #1588 - tenantcloud.elk_backup's elasticsearch_plugin task is skipped in --check

- Issue: https://github.com/weirdbricks/krikri/issues/1588
- Role: `tenantcloud.elk_backup` (rocky host, round `logs___1795043292`)
- Class: check-mode behaviour (module execution, exit code and recap)

**What diverged.** Real executes `elasticsearch_plugin` under `--check`
(community.general declares `check_mode: full`), and the module's
`get_plugin_bin()` installer probe runs before any state work, so a host
without Elasticsearch fails the task with

```
None does not exist and no other valid plugin installers were found. Make sure Elasticsearch is installed.
```

(that `None` is the unset `plugin_bin` parameter). krikri dropped the
task as an unimplemented community module, printed `skipping:`, ran on to
the role's `Copy elk scripts` task and reported *that* fatal instead, with
exit 4 (`uses unimplemented plugin: elasticsearch_plugin`) instead of
real's 2.

**Fixture.** The role's `tasks/main.yml` is copied verbatim (every task,
including the two later `copy:` tasks) and the play only adapts it to
localhost; `--check` is in `flags.txt`. `expected.out` was captured from
real ansible-core 2.21.6 with community.general 12.5.0.

**Fix.** `plugins/elasticsearch_plugin.cr` implements the module
(including this probe's exact failure), which also matches the
check-mode result shape the unit spec pins (`cmd`, `stdout_lines`,
`stderr_lines`, `url`, `timeout`).
