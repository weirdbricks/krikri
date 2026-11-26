# kpg 000018-multi-dpkg_divert-happy: Filesystem, check mode, happy path

- issue: https://github.com/weirdbricks/krikri/issues/1856
- playbook: `000018-multi-dpkg_divert-happy` (krikri-playbook-generator,
  seed 1795703658), second play's `Filesystem #18.1` task
- round: krikri 0.9.3151 (debug), commit 2db4c5e338c2

## What diverged

`community.general.filesystem` with `fstype: f2fs`, `state: present`,
`resizefs: true` against an existing regular file, run with `--check`. Real
Ansible fails the task:

```
Failed to find required executable "mkfs.f2fs" in paths: ...
```

krikri answered `changed: [target -> target2]` instead, so the recap differed
too (real: `changed=1 ignored=3`, krikri: `changed=2 ignored=2`).

Real `filesystem.py` reads `blkid`'s TYPE and then instantiates the per-fstype
class - `F2fs.__init__` (and `Btrfs.__init__`) resolve their `mkfs` binary with
`get_bin_path(required=True)` right there, before the same-fs/resizefs
branches and without a `check_mode` gate. `create()` is the only part that
honours check mode. krikri's plugin skipped straight to its own check-mode
shortcut, so the missing binary was never noticed.

## Corpus fit

The playbook is the generator's task, adapted only to point `dev:` at a file in
the case's own scratch tree. It needs a host without `f2fs-tools`, which is the
reference containers' state (and CI's: neither installs it) - a host that does
have `mkfs.f2fs` would take Ansible's other branch entirely (an `ok`/`changed`
answer for an f2fs image), so the case cannot be made tool-independent: the
binaries `get_bin_path` searches live in the same sbin directories `blkid` must
be found in.
