# #1666 - KAMI911.wildfly: `configure Wildfly` fails on a loaded bare `include:`

- Issue: https://github.com/weirdbricks/krikri/issues/1666
- Role: `KAMI911.wildfly` (rocky host, round `logs___1795231613`)
- Class: output gap (error text and ordering, run-time include failure)

**What diverged.** `tasks/main.yml` runs `configure Wildfly` as
`include_tasks: configure.yml`, and that file's line 281 is a bare
`- include: configure-properties.yml` - an action ansible-core removed. Real
loads the file at run time, so the include task itself fails: one
`[ERROR]`+`Origin` block on STDOUT right after the task banner, then
`fatal: ... FAILED! => {"changed": false, "msg": ...}`, then the recap.

krikri printed the same failure as 2.19 did: the block on STDERR after the
recap, its message repeated three times behind a `<<< caused by >>>` chain,
and a `{"changed": false, "include": ..., "reason": ...}` dump instead of
`msg`.

**Fixture.** The role's `tasks/configure.yml` and `tasks/configure-properties.yml`
verbatim; `tasks/main.yml` trimmed to the failing task (the role's real one
runs its install steps first, which would mutate the host - and never runs
here, since the file fails while it loads).
