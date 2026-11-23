# Issue #1724 - RedHatOfficial.rhel9_anssi_bp28_intermediary

Upstream issue: https://github.com/weirdbricks/krikri/issues/1724

Role: `RedHatOfficial.rhel9_anssi_bp28_intermediary` (rocky), round
`round29923752`.

## What diverged

The role's first task is

```yaml
- name: Gather the package facts
  ansible.builtin.package_facts:
    manager: auto
```

On the Rocky target `auto` resolves to the rpm manager (no apt there), and
real ansible-core 2.21.6 gathered the facts (`ok`) while krikri failed the
whole play:

```
Could not detect a supported package manager from the following list:
['apk', 'apt', ..., 'openbsd_pkg'], or the required Python library is not
installed. Check warnings for details.
```

## Why

ansible-core 2.21.6's rpm manager is a `CLIMgr`: it is usable whenever the
`rpm` binary is on the target's PATH (`get_bin_path`). krikri gated rpm on
the target python being able to `import rpm` - the requirement of the
2.9-era `LibMgr` - so a host with the CLI but no `python3-rpm` for the
interpreter ansible-core discovers (the Rocky 9 case: `/usr/bin/rpm` exists,
`import rpm` fails) skipped its only usable manager and reported found==0.
It also warned with `missing_required_lib`'s python text where real warns
with `get_bin_path`'s `Failed to find required executable "rpm" in paths:
...`.

## The case

The playbook runs the role's task with `manager: rpm`, the manager `auto`
resolves to on that target, so a dpkg host can exercise the same branch.
`bin/rpm` is a stub CLI (a case input, like another case's `always-fail`)
because the trigger is a real EL host's package tooling, which the fast
suite does not have; `env.txt` puts it on PATH. Before the fix the task
failed on the python-import gate; after it both engines gather the stub's
packages (`aide` with `epoch: "None"` proves the entry shape too).
