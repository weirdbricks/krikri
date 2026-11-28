# 1971 - apt: a wildcard `name:` was looked up as a literal package name

- Issue: https://github.com/weirdbricks/krikri/issues/1971
- Role: `kevinmagni.zabbix_agent2` (ubuntu), round round29930941
- Task: `Install Zabbix Agent 2 and plugins` (tasks/ubuntu.yml:38)

## What diverged

The task installs `[zabbix-agent2, zabbix-agent2-plugin-*]`. Real apt.py
expands any NAME carrying a glob character (`*?[]!`) against the apt cache
before resolving anything (`expand_pkgspec_from_fnmatches`), so the
wildcard installs every plugin package the configured zabbix repo carries
and the task reported `changed` (or `ok` on the warm run).

krikri-playbook instead looked the raw pattern up as a literal package
name, `apt-cache policy 'zabbix-agent2-plugin-*'` printed no stanza, and
the task failed:

```
fatal: [testhost]: FAILED! => {"changed": false, "msg": "No package(s) matching 'zabbix-agent2-plugin-*' available"}
```

so the role stopped one task early (ansible went on to `Configure Zabbix
Agent 2` and failed there on an undefined `zabbix_agent_server`).

## What this case pins

The issue's failing task, verbatim except for the wildcard name: the
zabbix repo is not on the capture box, so the expansion is pinned with
fnmatch's bracket class over `bash` instead - `[b]ash` matches exactly
one cache name, it is already installed, and neither engine runs apt-get.
Before the fix krikri failed with the plural no-match message; ansible
reports `ok`.

`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
