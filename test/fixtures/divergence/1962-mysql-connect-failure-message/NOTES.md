# 1962 - mysql_* connection-failure message wording

- Issue: https://github.com/weirdbricks/krikri/issues/1962
- Side note from #1960.

## What diverged

`mysql_info`, `mysql_query`, `mysql_db` and `mysql_variables` all reached a
refused connection (127.0.0.1:33399, nothing listening) and reported a
message real ansible.mysql never prints:

```
unable to connect to database, check login_user and login_password are correct or login_unix_socket password is empty: 
```

Real ansible-core 2.21.6 (ansible.mysql 5.2.0) wording:

- `mysql_query`/`mysql_user`: `unable to connect to database, check
  login_user and login_password are correct or <config_file> has the
  credentials. Exception message: (2003, "Can't connect to MySQL server on
  '127.0.0.1' ([Errno 111] Connection refused)")`
- `mysql_db`/`mysql_variables`: the same, except that when `config_file`
  does not exist their `os.path.exists` branch reports `unable to find
  <config_file>. Exception message: ...` instead.
- `mysql_info`: `unable to connect to database using <connector> <version>,
  check login_user and login_password are correct or <config_file> has the
  credentials. Exception message: ...`

Two separate defects fed the krikri message: the wording came from an old
community.mysql version that no longer exists anywhere, and the "Exception
message:" tail was `ex.message` over crystal-mysql's `DB::ConnectionRefused`,
which carries no message at all.

The `config_file` position is `os.path.expanduser`'d by AnsibleModule
(type='path', default `~/.my.cnf`), so it renders as `<HOME>/.my.cnf`; the
replay's scratch HOME is normalized to `<WORK>`.

## What this case pins

The real role's failing tasks adapted to localhost, each with
`ignore_errors: true` so one transcript carries every wrapper.

`mysql_info` is deliberately NOT in the case: its wrapper names the connector
version the TARGET's Python has installed ("using pymysql 1.2.3"), so a
recording would pin this box's PyMySQL build and fail on any host with a
different one (CI installs `python3-pymysql`). Its wording is pinned by the
plugin specs (`mysql_info_validation_test.cr`,
`mysql_connection_test.cr`) instead.

`env.txt` carries two overrides:

- `PYTHONPATH`: both engines must import PyMySQL to get past the module
  bootstrap's driver gate at all. The capture harness pins the pinned
  ansible-core's site-packages, and on this box PyMySQL lives in that same
  user site-packages - which the replay's scratch HOME hides. The entry is
  ignored where the path does not exist, so a host with PyMySQL in a system
  directory (CI) replays this unchanged.
- `ANSIBLE_DEPRECATION_WARNINGS=False`: real's ansible.mysql modules import
  `to_native` from the deprecated `ansible.module_utils._text` shim (a
  warning krikri can never print) and the short module names resolve through
  community.mysql's redirect table with a deprecation of their own. Neither
  is the message this case pins.

`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
