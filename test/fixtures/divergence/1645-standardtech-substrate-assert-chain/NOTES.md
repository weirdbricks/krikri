# #1645 - standardtech_bot.substrate_deployer: duplicate [ERROR] chain for a looped assert

- Issue: https://github.com/weirdbricks/krikri/issues/1645
- Role: `standardtech_bot.substrate_deployer` (ubuntu host, round `logs___1795172676`)
- Class: output gap (an extra `[ERROR]` chain block)

**What diverged.** The role's preflight assert loops over
`that: "{{ item }} is defined"`, which real ansible fails as an expression
syntax error. Real prints ONE two-level chain there - "Task failed." at the
task, then the `that:` item's syntax error - and krikri printed a second
chain ahead of it, pinned at the `import_tasks:` line's `when:` token
(line numbers are the round's own copy):

```
Task failed.
Origin: .../tasks/preflight.yml:12:3
<<< caused by >>>
Syntax error in expression. ... got '}'
Origin: .../tasks/main.yml:4:9        <- krikri only
```

**Fixture.** The role's `tasks/main.yml` first import (the `when:` that made
the second block visible) and the failing assert from `tasks/preflight.yml`
are copied verbatim; the import's `when:` with `defaults/main.yml`'s
`substrate_node_preflight: true` reproduces the round's shape. The role's
other imports and the two tasks above the failing one are dropped - the assert
fails first, so they never run, and the dropped systemd assert would depend on
the capturing host's service manager. `expected.out` was captured from real
ansible-core 2.21.6 (3662 bytes of transcript).

**Fix.** The looped display path decided whether to re-emit a `when:` chain
from the failed result's msg wording. An action plugin's own
conditional-shaped failure (assert's `that:` syntax error) shares that
wording, so it drove the `when:` emitter a second time; the duplicate only
stayed hidden while the task had no `when:` of its own, because both blocks
then pinned the same Origin and display dedup collapsed them. It now keys on
the result's `_ansible_when_error_emitted` marker, which only a real
`when:`/`until:` evaluation failure sets.
