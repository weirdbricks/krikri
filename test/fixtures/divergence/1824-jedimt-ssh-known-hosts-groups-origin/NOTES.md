# 1824 - jedimt.ssh: the loop-source miss's cause Origin points at the
# default that held the failing template

- Issue: https://github.com/weirdbricks/krikri/issues/1824
- Role: `jedimt.ssh` (rocky), round `logs___1795626220`
- Evidence: `logs___1795626220/jedimt_ssh/compare_cold.diff` (block 4)

## What diverged

`tasks/main.yml`'s first task loops `with_items: "{{ ssh_known_hosts }}"`, and
the role default templates `ssh_known_hosts: "{{ groups['servers'] }}"` for a
group the round's inventory never defined. Both engines fail the task with
`object of type 'dict' has no attribute 'servers'` and both point the outer
`Task failed.` block at the task's `name:` key, but the `<<< caused by >>>`
link named a different declaration:

```
-Origin: <WORK>/roles/jedimt.ssh/defaults/main.yml:5:18   # ansible
+Origin: <WORK>/roles/jedimt.ssh/tasks/main.yml:7:15      # krikri
```

Real templates the default lazily and tags the VALUE, so the chain's innermost
link is that definition's value token. krikri pinned the loop keyword's own
value token instead, because the loop-source chain only consulted the
defining-variable scan for the `LazyTemplateDict` message shape and fell
straight through to the loop-token fallback for the Python-style
`object of type '...' has no attribute ...` one.

The fix runs the same defining-value scan the template action's attribute-miss
uses before falling back, so a loop source that merely READS such a variable
names the definition; a source carrying the miss itself (`loop: "{{ d.ns }}"`
over a dict literal, issue #239) still lands on the loop keyword's token.

## Case

`playbook.yml` runs the role against localhost; `roles/ssh/tasks/main.yml` is
the role's `tasks/main.yml` copied verbatim and `roles/ssh/defaults/main.yml`
its `defaults/main.yml` verbatim (both engines fail on the first task, so the
later tasks never run). The inventory defines no `servers` group, which is
what makes the default's own template fail. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
