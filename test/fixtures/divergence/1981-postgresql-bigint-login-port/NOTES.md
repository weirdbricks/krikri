# 1981 - a BIGINT login_port crashed the plugin instead of libpq's option-parse error

- Issue: https://github.com/weirdbricks/krikri/issues/1981
- Found while fixing #1980 (the BIGINT demotion that makes the bare digits
  reach the connection helper).

## What diverged

`community.postgresql.*`'s `login_port` is `type: int`. A YAML integer wider
than Int64 reaches krikri as a `BIGINT_SENTINEL_PREFIX`-marked string, which
the plugin side demotes to its bare decimal digits (issue #1980). The
PostgreSQL connection helper then parsed that text with Int32's `String#to_i`
while building the connection URI, which raises
`ArgumentError: Invalid Int32` and surfaced as the engine's generic
`Plugin execution failed: ...` crash.

Real parses the literal into a width-free Python int and hands it to
psycopg2/libpq, whose own option parse (strtol into a C int) refuses it
before any connection method is chosen:

```
unable to connect to database: invalid integer value "999999999999999999999999" for connection option "port"
```

(the trailing newline is libpq's PQerrorMessage buffer's own).

## What this case pins

The single task. It is host independent: libpq's option parse runs before
TCP-vs-Unix-socket is decided, so no socket is ever touched and no server is
needed. The same wording also covers values that merely overflow Int32
(e.g. 3000000000), pinned by `test/unit/postgresql_connection_test.cr` and
the registered-result assertion in
`test/integration/postgresql_connection_messages_test.cr`. Related: #1982
(the in-Int32-range but out-of-port-range wording, fixed separately).
