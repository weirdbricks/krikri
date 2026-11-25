# 1788 - YasuhiroABE.homegw-network: with_items: over a bare list fact warns a block per item read

- Issue: https://github.com/weirdbricks/krikri/issues/1788
- Role: `YasuhiroABE.homegw-network` (ubuntu host, round `round29926391`)
- Class: output gap (extra stderr - two INJECT_FACTS_AS_VARS blocks real
  never prints)

## What diverged

The role's "delete all setting from interfaces" task
(`tasks/main.yml:15-24`) loops `with_items:` over a one-element entry holding
the bare fact `"{{ ansible_interfaces }}"`, re-reading `{{ item }}` in its
`lineinfile:` `regexp:`. Real ansible templated the loop source once - one
INJECT_FACTS_AS_VARS block, Origin'd at the `with_items:` entry - and printed
nothing more for the item. krikri printed two extra blocks after it: the same
deprecation again at the `regexp:` line (the first item's `{{ item }}` read)
and a `While processing 'item'` block with `Origin: <unknown>`.

## Why

Ansible tags the deprecated fact's VALUE, not its name, and `with_items:`
flattens one level before iterating: the array-wrapped entry resolves to the
fact's own list, and the iteration hands out that list's ELEMENTS, which are
untagged. krikri carried the source's fact tether (set for
`with_items: - "{{ ansible_<fact> }}"`) into the per-item render, so each
`{{ item }}` read and the item label re-warned. A scalar-wrapped source is
different: its single item IS the tagged value, so `loop:` over
`["{{ ansible_user_id }}"]` still warns per read (issue #1221, pinned by
`inject_facts_deprecation_test.cr`).

## Case

`playbook.yml` is the role's failing task verbatim (`tasks/main.yml:15-24`)
with two localhost adaptations. `path: /etc/network/interfaces` became the
relative `interfaces`: the case must not touch the host's own file, and with
a path that does not exist the role's `state: absent` stays the no-op it was
on the round's host. The loop source became `"{{ ifaces }}"`, reported by the
case-local `library/iface_facts.py` module: the role loops over
`ansible_interfaces`, whose length and contents are the target's own, so the
per-item `ok:` lines could never be pinned in a fixed expected.out. A
module's `ansible_facts` entry is injected as a top-level fact by both
engines, so the deprecation under test is unchanged.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`; `inventory.ini` pins the interpreter on the
`[local]` host.
