# 1966 - extract's attribute miss is not wrapped as a filter-plugin failure

- Issue: https://github.com/weirdbricks/krikri/issues/1966
- Role: `bmeme.percona_xtradb_cluster` (2.2.0, rocky), round round29930958,
  krikri 0.9.3216.

## What diverged

`tasks/ip.yml` builds `all_ips` from every host's cluster address:

```yaml
all_ips: >-
  {{ ansible_play_hosts |
  map('extract', hostvars, ['percona_cluster', 'ip_address']) |
  join(',') }}
```

Role defaults are not visible through `hostvars`, so the first `extract`
step misses `percona_cluster` on the hostvars entry. ansible's `extract`
filter returns the undefined marker for that miss and the attribute error
surfaces later, when `join` consumes it - outside the filter plugin's own
wrapper - so the task reports just the getitem wording:

    Error while resolving value for 'all_ips': object of type 'HostVarsVars' has no attribute 'percona_cluster'

krikri raised the miss inside the filter and `FilterEngine#apply` wrapped it
as a plugin failure, so the task carried an extra
`The filter plugin 'ansible.builtin.extract' failed: ` prefix in the error
banner, the caused-by stanza and the fatal dump. The case asserts the real
transcript (captured from ansible-core 2.21.6) with no wrapper.

## Case

The role's `defaults/main.yml` and the failing `tasks/ip.yml` are copied
verbatim; `tasks/main.yml` keeps only the `IPs assertions` include, since
`variables.yml` (which runs first in the real role) only defines internal
`percona_*` facts this task never reads and needs a real distro's vars file.
The case runs with `gather_facts: false` so `ansible_default_ipv4` (read by
the role default's `ip_address`) is never needed.

## Not covered here

The round transcript also showed one EXTRA `INJECT_FACTS_AS_VARS`
deprecation block after the recap (the whole block-25 byte delta): krikri
renders every leaf of a container value when a dotted access needs one, so
the sibling `ip_address: "{{ ansible_default_ipv4.address }}"` role default
reads a fact ansible's lazy value never touches. That is the tier-3 cosmetic
warning class `KNOWN_MISSING.md` keeps best-effort, not this issue's
structured-output divergence; this case pins the error wording.
