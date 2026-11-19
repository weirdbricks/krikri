# #1573 - vbotka.freebsd_ports prints an extra INJECT_FACTS_AS_VARS block

- Issue: https://github.com/weirdbricks/krikri/issues/1573 (recurrence of #1167)
- Role: `vbotka.freebsd_ports` (rocky host, round `logs___1795043292`)
- Class: output gap (extra stderr)

**What diverged.** Real ansible printed three `[DEPRECATION WARNING]:
INJECT_FACTS_AS_VARS` blocks, all Origin'd into the role's `tasks/vars.yml`.
krikri printed a fourth one, Origin'd at
`roles/vbotka.freebsd_ports/defaults/main.yml:32:23` - the role default
`ports_portsnap_index: "{{ ansible_distribution_major_version }}"`.

Real never templates that default: the only tasks that read it are gated false
(`ports_config`/`ports_debug`), so nothing consumes it. krikri's task-level
`vars:` probe (`strict_var_value_miss`) resolved it while building the skipped
debug task's context, and the fact read warned. A `must_include` style test
could never have caught this: the three real blocks were all present.

**Fixture.** `defaults/main.yml` and `tasks/vars.yml` + `tasks/debug.yml` are
the role's files verbatim, so the default stays on line 32 with column 23 (the
`{{`). `tasks/main.yml` keeps only the two imports that precede the shape
(`vars.yml`, `debug.yml`) - the rest of the role writes to `/usr/ports` etc.
`playbook.yml` is the round's play with localhost in place of `testhost`.
