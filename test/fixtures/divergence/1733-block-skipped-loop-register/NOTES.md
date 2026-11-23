# 1733 - t2d.ansible_role_libvirt_vm: a block-skipped loop's register loses its results

- Issue: https://github.com/weirdbricks/krikri/issues/1733
- Role: `t2d.ansible_role_libvirt_vm` (rocky), round `round29923774`
- Evidence: `logs___1795423891/t2d_ansible_role_libvirt_vm/compare_cold.diff` (block 10)

## What diverged

The role's `tasks/autodetect.yml` runs two loops inside a block gated on
`when: libvirt_vm_engine == 'kvm'`. On an engine other than kvm both are
skipped, and the second loops over the first's register:

```yaml
        - name: Detect the KVM emulator binary path
          stat:
            path: "{{ item }}"
          register: kvm_emulator_result
          with_items: [...]

        - name: Set a fact containing the KVM emulator binary path
          set_fact:
            libvirt_vm_emulator: "{{ item.item }}"
          with_items: "{{ kvm_emulator_result.results }}"
          when: item.stat.exists
```

Real ansible records every item of a skipped loop in the register's loop
aggregate (`changed`, `failed`, `skipped`, `msg: "All items skipped"`, and a
`results` entry per item carrying the block's clause as `false_condition`), so
the second task's loop source resolves to three items and prints one
`skipping: [testhost] => (item=...)` line each. krikri registered the flat
conditional-skip dict instead - no `results` key - so
`kvm_emulator_result.results` was undefined, the second loop had zero items,
and it printed a single bare `skipping: [testhost]` line.

The fix gives the when:-false-block skip path the same loop aggregate the
executed loop path builds, plus the distinct "No items in the list" aggregate
for an empty source; an undefined or unrenderable source still collapses to
the flat skip dict, exactly like real. The skipped block also hands down only
the clause that evaluated False (the inner block's here), not the merged
"(parent) and (child)" text its condition list was built from, which is what
real reports as `false_condition`.

## Case

`playbook.yml` carries `tasks/autodetect.yml`'s second top-level block
verbatim, with `libvirt_vm_engine: qemu` pinned so neither the `/dev/kvm`
modprobe nor the emulator probe runs and the case stays read-only.
`expected.out` is `bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
