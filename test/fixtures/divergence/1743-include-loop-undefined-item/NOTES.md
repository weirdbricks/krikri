# 1743 - t2d.ansible_role_libvirt_vm: a looped include_tasks over a default holding an undefined var

- Issue: https://github.com/weirdbricks/krikri/issues/1743
- Role: `t2d.ansible_role_libvirt_vm` (rocky), round `round29923774`
- Evidence: `logs___1795423891/t2d_ansible_role_libvirt_vm/compare_check.diff`

## What diverged

The role's `tasks/main.yml` loops `include_tasks: volumes.yml` over
`libvirt_vms`, whose default (defaults/main.yml:47-79) is the
backwards-compatibility singleton list of the deprecated variables. Nobody set
`libvirt_vm_name` (the role documents it as required, along with memory_mb and
vcpus), so templating the loop source hits an undefined name - real
ansible-playbook fails the include_tasks: statement right there:

```
[ERROR]: Task failed: 'libvirt_vm_name' is undefined
<<< caused by >>>
'libvirt_vm_name' is undefined
Origin: .../roles/t2d.ansible_role_libvirt_vm/defaults/main.yml:52:13
```

krikri rendered include_tasks:'s loop items leniently, so the missing name
became this engine's literal "undefined" sentinel: the item printed as
`{'name': 'undefined', ...}`, volumes.yml and vm.yml loaded and ran (all
skipped in check mode), the recap went green (failed=0), and the play exited 4
instead of 2. Ansible templates the whole loop list strictly before iterating
(`run()` -> `_get_loop_items`), and only defers that error so a task-level
`when:` that is False without `item` bound can still skip the task - the same
ordering the ordinary looped-task path already implements, now shared with
this include path.

## Case

`playbook.yml` carries the role's looped `include_tasks: volumes.yml`
(tasks/main.yml:18-24) with the `libvirt_vms` default entry trimmed to the
fields that decide the failing leaf (`name` is the first undefined one; `state`
is pinned to the role's own null deprecated default so it resolves), run under
`--check` like the round's check phase. `included.yml` stands in for
`volumes.yml`'s first task, which real never reaches. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
