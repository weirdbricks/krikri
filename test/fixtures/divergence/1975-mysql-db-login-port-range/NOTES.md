# 1975 - mysql_db never validated login_port against the unix port range

- Issue: https://github.com/weirdbricks/krikri/issues/1975
- Follow-up from #1961.

## What diverged

`mysql_db.py:665-667` reads `login_port` into an int and fails the task when
it is outside 0-65535, in its own `main()` - after the empty-name exit, before
the `chdir:` handling, the state branches and any connect. krikri's
`plugins/mysql_db.cr` carried no such check, so:

- `login_port: -5` crashed the URI builder and surfaced as the engine's
  internal-error wrapper, `Plugin execution failed: Invalid URI: bad port at
  character 25`.
- `login_port: 70000` fell through to a connection attempt, reporting the
  connection-failure wrapper where real fails on the range check.
- `login_port: 99999999999999` surfaced as `Plugin execution failed: Invalid
  Int32: "99999999999999"`.

Real fails every one of them with exactly:

```
login_port must be a valid unix port number (0-65535)
```

and does so for `state: dump` too (before the missing `target:` is ever
checked), which the last task in this case pins.

## The fix

`MysqlDbPlugin#login_port_range_error` runs at real's position (after the
empty-name exit, before `chdir:`), accepting anything outside 0..65535 -
including integer text past Int64, which real's unbounded `int()` still reads
as a number.

## What the issue's own repro does NOT show

The issue's stated trigger - a non-integer `connect_timeout` reaching
`MysqlConnection.build_uri` - does not reproduce through `krikri-playbook`:
the baked argspec table (`data/argspecs.json`, `src/krikri/argspec_validator.cr`)
carries the full `ansible.mysql.mysql_db`/`mysql_user` specs, and a task with
`connect_timeout: abc` fails controller-side with real's exact
"argument 'connect_timeout' is of type str and we were unable to convert to
int" message, on every path tried (literal, templated var, dict var,
`module_defaults`, loop, async, `--check`, bare module name, `action:`). The
reachable half of the same gap is the integer range itself, pinned by the
sibling case 1975-mysql-connect-timeout-bigint.
