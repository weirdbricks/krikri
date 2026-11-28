# 1979 - a YAML int wider than Int64 failed the `type='int'` argument spec

- Issue: https://github.com/weirdbricks/krikri/issues/1979
- Found while verifying #1977.

## What diverged

A YAML integer wider than Int64 travels through krikri as a
`BIGINT_SENTINEL_PREFIX`-marked string (`src/krikri/param_sentinels.cr`). Real
ansible parses it into a Python int, which has no width, so the module receives
it and fails in its own wording. krikri failed the argument spec instead,
because `ArgspecValidator#int_like?` (and the plugin-side
`AnsibleArgValidation.int_convertible?`) could not read the marker:

```
argument 'login_port' is of type str and we were unable to convert to int
```

Real instead runs the module:

- `login_port: 999999999999999999999999` - Python hands getaddrinfo a service
  whose low 32 bits have bit 31 set, so it is refused with `EAI_SERVICE` and
  never dials: `(2003, "Can't connect to MySQL server on 'localhost' ([Errno -8]
  Servname not supported for ai_socktype)")`. krikri reduced the port modulo
  65536 and dialled the residue instead.
- `connect_timeout: 999999999999999999999999` - PyMySQL's own range check runs
  before any socket exists and reports
  `connect_timeout should be >0 and <=31536000`.

## What this case pins

Both tasks, because both are host independent: neither reaches a socket.
`krikri.bigint_digits` is also covered by `test/unit/argspec_validation_test.cr`
(validator) and `test/integration/mysql_login_port_text_test.cr` (plugin
helpers), which include the getaddrinfo service rule in `MysqlConnection`.
