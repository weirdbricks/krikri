# 1731 - lotusnoir.apps_snoopy: PLAY RECAP loses an INJECT_FACTS_AS_VARS block

- Issue: https://github.com/weirdbricks/krikri/issues/1731
- Role: `lotusnoir.apps_snoopy` (rocky), round `logs___1795423891`
- Evidence: `logs___1795423891/lotusnoir_apps_snoopy/compare_cold.diff` (block 7)

## What diverged

Real ansible prints one more deprecation block than krikri, Origin'd at the
role's `tasks/main.yml:13:11` - the first entry of the `params_` list:

```yaml
params_:
  files:
    - "{{ ansible_distribution | lower }}-{{ ansible_distribution_version | lower }}.yml"
```

The task never templates `params_` as a module argument: `params` consumes it
through `lookup('first_found', params_)`, and the only render that reads
`params` is the task's own `when: (params | length > 0)`. Real templates
`params` lazily at that when: evaluation, which renders `params_`'s entries in
the same operation and reads `ansible_distribution` there.

krikri renders task `vars:` values eagerly at vars-context build and records
the fact readings for whoever consumes the value, but the recording made for
`params_` had no consumer of its own to replay it: `params_` is only resolved
while `params`'s eager render is open (a capture), where the flush was
suppressed. The readings stayed pending forever, so the block never printed.

## Case

`playbook.yml` is the role's include_vars task copied verbatim, with a
`vars/default.yml` fallback entry so first_found matches on any distribution
and the task itself completes. `expected.out` is `bin/krikri-capture-case`'s
capture from ansible-core 2.21.6.
