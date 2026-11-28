# 1975 - a connect_timeout past Int32 was silently dropped, not range-checked

- Issue: https://github.com/weirdbricks/krikri/issues/1975
- Follow-up from #1961.

## What diverged

Python's `int()` has no width, so `connect_timeout: 99999999999999` is a valid
integer to the modules' argument spec (`type='int'`) and it is PyMySQL's own
`__init__` range check - before any socket exists - that rejects it:

```
Exception message: connect_timeout should be >0 and <=31536000
```

`MysqlConnection.connect_timeout_out_of_range?` (added by #1961) parsed the
value with Crystal's `#to_i?`, which stops at Int32, so this value looked
non-integer and the guard returned false. The shard then dropped the value
(no socket timeout at all, the unbounded connect the guard exists to prevent)
and krikri reported a connection failure where real fails on the range check.

## The fix

The guard now requires all-digit text (`INTEGER_TEXT`) and parses it with
`#to_i64?`: a value past Int64 - still a number to real - is out of range too.
Non-integer text keeps its previous behaviour (the baked argspec validator
rejects it before the plugin runs, with the argument-spec wording).

The case pins all four plugins that share the guard: `mysql_db`,
`mysql_user`, `mysql_query` and `mysql_variables`. `mysql_info` is not in it -
its connection-failure wrapper names the connector version the target host's
Python has installed ("using pymysql 1.2.3"), see #1962/#1961.

## Not fixed here

A `login_port` that is not a plain 0..65535 decimal (negative, past Int32, or
Python's `1_000` spelling) in `mysql_user`/`mysql_info`/`mysql_query`/
`mysql_variables` (only `mysql_db` validates the range, see
1975-mysql-db-login-port-range) still raises inside the URI builder and
surfaces as the engine's internal-error wrapper. Real has no range check on
those modules, so its failure is a live connection attempt whose
`getaddrinfo` errno text is host-specific and no transcript can pin; tracked
in issue #1977.
