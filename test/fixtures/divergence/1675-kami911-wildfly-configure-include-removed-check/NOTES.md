# #1675 - KAMI911.wildfly: `configure Wildfly` fails the same way under --check

- Issue: https://github.com/weirdbricks/krikri/issues/1675
- Role: `KAMI911.wildfly` (rocky host, round `logs___1795231613`)
- Class: check-mode output gap (error text and ordering, run-time include failure)
- Same root cause as #1666, one phase later

**What diverged.** `tasks/main.yml` runs `configure Wildfly` as
`include_tasks: configure.yml`, and that file's line 281 is a bare
`- include: configure-properties.yml` - an action ansible-core removed. Loading
an included file is not skipped under `--check`: real still parses it, so the
include task itself fails with one `[ERROR]`+`Origin` block on STDOUT right
after the task banner, then `fatal: ... FAILED! => {"changed": false, "msg":
...}`, then the recap. The play had already reached 23 `ok` tasks in check
mode, so the recap printed the round's counters.

krikri printed the ansible 2.19 shape: the block on STDERR after the recap, its
message repeated three times behind a `<<< caused by >>>` chain, and a
`{"changed": false, "include": ..., "reason": ...}` dump instead of `msg`.

**Fixture.** The role's `tasks/configure.yml` and
`tasks/configure-properties.yml` verbatim (shared with #1666's case);
`tasks/main.yml` trimmed to the failing task, because the role's real one
runs its install steps first - which never run here, as the include task fails
while its file loads. `flags.txt` runs the case with `--check`.
