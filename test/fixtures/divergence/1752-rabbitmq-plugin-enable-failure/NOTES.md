# `community.rabbitmq.rabbitmq_plugin`: a failed enable reports the command's own output

- issue: #1752 (https://github.com/weirdbricks/krikri/issues/1752)
- task: `Rabbitmq_plugin #27.0` (kpg playbook `000027-multi-rabbitmq_plugin-happy`)
- phase: run

## What diverged

The broker was reachable, `rabbitmq-plugins list -E -m` succeeded, and
`rabbitmq-plugins enable --online wufeut` exited 70 because no such plugin
exists. The module calls every `rabbitmq-plugins` invocation through
`run_command(..., check_rc=True)`, so basic.py authored the failure: `msg` is
the bare rstripped stderr (`"Error:\n{:plugins_not_found, [:wufeut]}"`) and
`cmd`, `rc`, `stdout`, `stderr` plus the controller-derived `stdout_lines` /
`stderr_lines` ride along in the result.

krikri reported a "Failed to enable plugin wufeut: ..." msg of its own (with
the trailing newline kept, which also printed an extra blank line in the
`[ERROR]` block) and dropped every other key, leaving only
`{"changed": false, "msg": ...}`.

The same module parity work also covers what the reference module does around
that call, all live-verified against ansible-core 2.21.6 + community.rabbitmq
on this host: every enable/disable carries the `--<broker_state>` flag, the
binary comes from `<prefix>/bin` or `<prefix>/sbin` (else `No binary folder in
prefix X`) or from `get_bin_path(required=True)` (else
`Failed to find required executable "rabbitmq-plugins" in paths: ...`), and a
successful task returns only `changed`/`enabled`/`disabled` - `exit_json` adds
no `msg`.

## Case adaptations

- `playbook.yml` is the issue's task on the local connection. The round's host
  reached a real broker through `/usr/sbin/rabbitmq-plugins`; the case ships a
  `rabbitmq/bin/rabbitmq-plugins` reproducing that broker's output for this
  call (same stdout, the `{:plugins_not_found, [:wufeut]}` stderr, rc 70) and
  selects it with `prefix:`, so the pin does not depend on the harness PATH
  (and the `cmd` in the result names the case's own binary).
- `delegate_to` is dropped: a localhost capture cannot reach the round's
  `target2`, and delegation changes nothing about the module's result.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 0).
