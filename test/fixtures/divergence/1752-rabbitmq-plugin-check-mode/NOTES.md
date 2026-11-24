# `community.rabbitmq.rabbitmq_plugin` under `--check`: report, do not run

- issue: #1752 (https://github.com/weirdbricks/krikri/issues/1752)
- task: `Rabbitmq_plugin #27.0` (kpg playbook `000027-multi-rabbitmq_plugin-happy`)
- phase: check (`--check`)

## What diverged

The module declares `supports_check_mode=True` and its `_exec` runs only the
listing under check mode (`force_exec_in_check_mode=True`), skipping every
enable/disable. Real therefore reported `changed` with
`enabled: ["wufeut"], disabled: []` and never called the CLI at all.

krikri ran `rabbitmq-plugins enable --online wufeut` for real under `--check`,
so the fixture broker's `plugins_not_found` failure made the task fail (and,
because the task ignores errors, the run reported `changed=0 ignored=1` where
real reported `changed=1`).

## Case adaptations

- Same fixtures as `1752-rabbitmq-plugin-enable-failure`: the task on the local
  connection, with `rabbitmq/bin/rabbitmq-plugins` selected through `prefix:`.
  The shim exits 70 on every enable, so this pin also proves check mode never
  invokes it.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 0).
