# 1977 - mysql_* plugins crashed on login_port text Ansible's int conversion accepts

- Issue: https://github.com/weirdbricks/krikri/issues/1977
- Found while fixing #1975.

## What diverged

AnsibleModule converts a `type='int'` parameter with `decimal.Decimal` and
requires it to equal its own integer truncation, so `login_port: -5`,
`"1_000"`, `70000` and `99999999999999` all reach the mysql modules as plain
integers. The four modules that carry no port range check of their own
(`mysql_user`, `mysql_info`, `mysql_query`, `mysql_variables`) hand that int to
PyMySQL, which fails the task in the module's own connection-failure wording:

    (2003, "Can't connect to MySQL server on 'localhost' ([Errno -8] Servname not supported for ai_socktype)")

krikri passed the raw task text to `MysqlConnection.build_base_uri`, which
raised inside the plugin, so the task failed with the engine's internal-error
wrapper instead: `Plugin execution failed: Invalid URI: bad port` for `-5`,
`Plugin execution failed: Invalid Int32` for a value past Int32, and a URI the
shard then rejected for `"1_000"`. `connect_timeout: "1_000"` was dropped
silently (no timeout at all) where real connects with 1000s.

## What this case pins

Only the tasks whose failure is host independent:

- a negative port never reaches a socket - `getaddrinfo` refuses the service
  with `EAI_SERVICE`, so real's wrapper text (and the `<WORK>/home/.my.cnf`
  option-file wording `mysql_variables` picks when the file is absent) is the
  same everywhere;
- `mysql_db`'s own 0-65535 check runs after the conversion, so the underscored
  `"-1_0"` (Decimal's -10) still lands on its range message.

`mysql_info` is left out because its wrapper names the PyMySQL version real
reports, which is not pinned here. Ports that do dial (`70000`, `"1_000"`,
`99999999999999`) are left out because glibc truncates the service to its low
16 bits and real's errno then depends on what listens on that port; their
failure shape is covered by `test/integration/mysql_login_port_text_test.cr`.

`env.txt` is the #1975 case's: PyMySQL has to be importable for both engines to
reach the connection-failure wrapper at all, and the replay's scratch `HOME`
hides the user site-packages the capture used.
