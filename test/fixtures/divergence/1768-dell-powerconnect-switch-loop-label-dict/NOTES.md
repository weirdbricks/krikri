# #1768 - a mapping `loop_control.label` refuses the whole run in real ansible

- Issue: https://github.com/weirdbricks/krikri/issues/1768
- Role: `pabluskinc.dell_powerconnect_switch` (rocky, round29925793)
- Class: playbook load-time refusal (exit code 4 vs krikri's 2)

**What diverged.** The role's third task sets a mapping as the loop label:

```yaml
  loop_control:
    label:
      interface: "{{ item.key }}"
      description:  "{{ item.value.description | default('<none>') }}"
      config: "{{ item.value.config | default([]) }}"
```

ansible-core's `LoopControl.label` is an `isa='string'` field, and
`Base.validate` refuses a list/dict in one at task load, before any play
banner:

```
[ERROR]: The field 'label' is supposed to be a string type, however the incoming data structure is a <class 'ansible.module_utils._internal._datatag._AnsibleTaggedDict'>
Origin: <WORK>/roles/pabluskinc.dell_powerconnect_switch/tasks/main.yml:57:7
```

so the round's ansible run never started the play (rc=4, deprecation
warnings only). krikri read the mapping with `as_h?`/`as_s?`, dropped the
label it could not type and RAN the role, ending with rc=2 at the pip task's
`become` failure - the exit code, block count and every following line
diverged.

**Fixture.** The role's own `tasks/main.yml`, `defaults/main.yml`,
`vars/main.yml` and `meta/main.yml` are copied verbatim from the round's
role, and `playbook.yml` runs it with switch vars against localhost (the
load-time refusal happens before the tasks execute, so no switch is needed).
`expected.out` was captured from real ansible-core 2.21.6.

**Fix.** `PlaybookParser.parse_loop_control` now validates a task's
`loop_control:` the way real ansible does at load time - a non-mapping
value, an unknown key, and a list/dict in `loop_var`/`index_var`/`label` -
raising `LoopControlError` (the rendered `[ERROR]` + `Origin` block, rc=4,
no play output) instead of silently ignoring what it cannot type. All four
task-parsing branches (plain tasks, include_vars, include_tasks,
include_role) share it.
