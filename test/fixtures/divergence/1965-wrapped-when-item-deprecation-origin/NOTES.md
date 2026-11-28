# #1965 - RedHatOfficial.rhel8_anssi_bp28_high: a wrapped `when:` item's deprecation Origin is the item, not the `when:` key

- Issue: https://github.com/weirdbricks/krikri/issues/1965
- Role: `RedHatOfficial.rhel8_anssi_bp28_high` (ubuntu, round round29930909)
- Class: output gap - the `Origin:` line of the INJECT_FACTS_AS_VARS
  deprecation block

**What diverged.** The role gates "Ensure dnf-automatic is installed" on a
`when:` list whose last item is a YAML plain scalar wrapped over three
physical lines:

```yaml
  - ( not ( "kernel-core" in ansible_facts.packages and "bootc" in ansible_facts.packages and not "openshift-kubelet" in ansible_facts.packages
    and "ostree" in ansible_proc_cmdline ) and not ( ansible_virtualization_type in ["docker", "lxc", "openvz", "podman",
    "container"] ) )
```

The deprecated top-level fact (`ansible_virtualization_type`) is named on
the item's SECOND physical line. Real ansible templates the folded item as
one value and Origin'd the deprecation at the item's own scalar token
(`tasks/main.yml:179:5`, the `(` after the dash). Krikri matched list items
by their first line only, so neither the evaluated clause nor the fact name
was found in the item, and it fell back to the `when:` key's value token
(`172:8`).

**Fix.** `ResultDisplay.conditional_value_origin` folds each item's wrapped
continuation lines into the item text (the way YAML does) before matching
the evaluated clause and the fact name, so both land on the item's own
line. The excerpt and column are unchanged for single-line items.

**Fixture.** The failing task is kept verbatim, asking `debug` instead of
`ansible.builtin.package` (the module needs a root dnf host and the
divergence is only the conditional's Origin). A `package_facts` task
precedes it - the `when:` reads `ansible_facts.packages`. The role's other
tasks all mutate the machine and are left out; `defaults/main.yml` keeps
the six gate variables' verbatim values. `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.
