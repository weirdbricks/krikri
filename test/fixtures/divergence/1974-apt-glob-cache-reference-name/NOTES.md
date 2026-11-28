# 1974 - apt: a wildcard was expanded to a name the cache only references

- Issue: https://github.com/weirdbricks/krikri/issues/1974
- Role: `kevinmagni.zabbix_agent2` (ubuntu), round round29930941
- Task: `Install Zabbix Agent 2 and plugins` (tasks/ubuntu.yml:38), `--check`

## What diverged

The task installs `[zabbix-agent2, zabbix-agent2-plugin-*]` in check mode.
Real apt.py expands a NAME carrying a glob character (`*?[]!`) with
`fnmatch.filter` over python-apt's cache iteration, which only yields
packages the cache holds at least one version of. This engine expanded
against `apt-cache pkgnames --all-names`, which is wider: it also lists
every name the cache merely references, purely virtual ones included
(trixie's `vim-gnome` has no versions at all, it survives only in
gtimelog's `Depends: vim-gnome`).

For a pattern that matched such a name, apt.py never selected it where
this engine acted on it: `name: vim-g*` on trixie reported `changed` in
check mode under ansible and failed here with the singular

```
fatal: [localhost]: FAILED! => {"changed": false, "msg": "No package matching 'vim-gnome' is available"}
```

so a check-mode role task stopped one task before ansible's own next
failure (the issue's `Configure Zabbix Agent 2`).

## What this case pins

The issue's task, verbatim except for the wildcard: no capture box has
the zabbix repo, so the pattern is one whose only apt-cache name is
purely virtual - `vim-gnome*` - next to the bracket class over the bash
every Debian host has, the way the 1971 case pinned its expansion.
Neither engine runs apt-get: real apt.py finds no fnmatch match and
fails the pattern with the plural wording before any apt-get call, and
this engine must do the same (before the fix it substituted the virtual
name and failed with the singular one).

`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
