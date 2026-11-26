# 1846 - mrlesmithjr.ansible_freeipa_server: the loop item's chain Origin
# points at the role default its own value failed in

- Issue: https://github.com/weirdbricks/krikri/issues/1846
- Role: `mrlesmithjr.ansible_freeipa_server` (rocky), round `logs___1795686235`
- Evidence: `logs___1795686235/mrlesmithjr_ansible_freeipa_server/compare_cold.diff`

## What diverged

The role's first included task (`tasks/hostname.yml`) loops a literal
`with_items:` list whose second entry is a bare reference to the role default
`freeIPA_server_ip_address`. That default templates
`hostvars[inventory_hostname]['ansible_' + freeIPA_server_ip_int]`, and a host
without the `enp0s8` interface has no such fact, so both engines fail the task
with `object of type 'HostVarsVars' has no attribute 'ansible_enp0s8'` and pin
the outer `Task failed.` block at the task's `name:` key. The
`<<< caused by >>>` link named a different declaration:

```
-Origin: <WORK>/roles/mrlesmithjr.ansible_freeipa_server/defaults/main.yml:33:28   # ansible
+Origin: <WORK>/roles/mrlesmithjr.ansible_freeipa_server/tasks/hostname.yml:9:7    # krikri
```

Real templates the default lazily and tags the value, so the chain's innermost
link is that definition's value token. krikri already ran that defining-value
scan for a TEMPLATED loop source (issue #1824), but a literal item list has no
loop source text to seed the reachability scan from, so the scan stayed
ambiguous and the locator fell back to the loop's first item. It also could not
reproduce the message at all for this shape: `value_failure_var_origin`'s probe
re-render never saw `hostvars` or `inventory_hostname`, so the default failed
with `'hostvars' is undefined` instead of the HostVarsVars miss.

The fix merges the hostvars view and the host's `inventory_hostname` into that
probe's vars (as it already does for facts and for `groups`), and seeds the
scan from each literal loop entry in turn, so the failing entry's referenced
definition names the cause. A loop source that carries the miss itself
(`loop: "{{ d.ns }}"` over a dict literal, issue #239) still lands on the loop
keyword's token.

## Case

`playbook.yml` runs a trimmed copy of the role against localhost with
`gather_facts: false`, which is what keeps the `ansible_enp0s8` miss
deterministic (real hosts in the round gathered facts and simply had a
differently-named interface). `roles/.../tasks/hostname.yml` and
`roles/.../defaults/main.yml` are the role's files verbatim; `tasks/main.yml`
keeps only the `include_tasks: hostname.yml` that fails, since the later
includes never run. `expected.out` is `bin/krikri-capture-case`'s capture from
ansible-core 2.21.6.
