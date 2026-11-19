# #1526 - robertdebock.sudo_pair: an environment: entry's fact read warns

- Issue: https://github.com/weirdbricks/krikri/issues/1526
- Role: `robertdebock.sudo_pair` (round `logs___1795001446`, check phase)
- Class: output gap (missing deprecation block)

**What diverged.** The role's `Build sudo_pair` task sets
`environment: PATH: "{{ ansible_env.PATH }}:/usr/local/bin"`. Real templates
the environment dict's leaves as tagged YAML scalars, so the top-level
`ansible_env` read prints the INJECT_FACTS_AS_VARS block with its Origin at
that entry's value token; krikri rendered the leaves with no templated-param
site registered, so the read had no placeable Origin and the block vanished.

**Fixture.** The role's task verbatim, plus the role's `defaults/main.yml` and
`vars/main.yml` (the task's `chdir:`/`creates:` need
`sudo_pair_unpack_directory`). `flags.txt` runs it in `--check` mode and points
`sudo_pair_unpack_directory` at a small relative tree shipped with the case, so
the command task is not executed - real reports it `changed`, which is
deterministic - while the `environment:` templating (the actual pin) still runs.
