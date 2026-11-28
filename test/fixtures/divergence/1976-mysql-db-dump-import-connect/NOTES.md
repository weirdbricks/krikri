# 1976 - mysql_db dump/import never connected before shelling out

- Issue: https://github.com/weirdbricks/krikri/issues/1976
- Follow-up from #1961.

## What diverged

Real `mysql_db.py` calls `mysql_connect(..., connect_timeout=connect_timeout)`
before any state branch, so `state: dump`, `state: import` and their
check-mode exits all fail against a host whose SYN is silently dropped
(192.0.2.1, RFC 5737 TEST-NET-1), at that timeout:

```
unable to find <HOME>/.my.cnf. Exception message:
(2003, "Can't connect to MySQL server on '192.0.2.1' (timed out)")
```

krikri's dump/import path went straight to `mysqldump`/`mysql` without a
plugin-side connection, so the task waited out the CLI's own OS-level
connect timeout instead (and check mode reported `changed` without ever
touching the server).

## What this case pins

All three tasks: dump, import and a check-mode dump. None can mutate
anything, because the connect - and its failure - happens before the CLI
runs. The blackholed host makes real's wrapper text host independent, the
same way the 1961 case pins the present-state connect; `ignore_errors`
keeps every wrapper in one transcript.

## Known remaining differences (not this issue)

- A reachable server still sees no dump/import existence handling: real
  fails a dump of a missing database ("Cannot dump database(s) ... - not
  found") and creates a missing database before an import, while krikri
  hands the name to the CLI. A live-server case for that needs its own issue.
- A reachable server's check-mode dump still exits krikri's way ("Would
  dump ...") instead of real's `changed`/`db`/`db_list` shape.
- An authentication failure (MySQL 1045) is wrapped by krikri's
  `query_failed` wording rather than real's unable-to-connect wrapper; that
  predates this case and also affects `state: present`/`absent`.
