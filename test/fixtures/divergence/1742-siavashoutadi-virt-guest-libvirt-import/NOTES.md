# 1742 - siavashoutadi.virt_guest: libvirt not importable under --check

Issue: https://github.com/weirdbricks/krikri/issues/1742
Role: `siavashoutadi.virt_guest` (ubuntu), round `round29923775`

## What diverged

`community.libvirt.virt` is not ported and krikri dropped its tasks as
"uses unimplemented plugin", printing `skipping:` for both the define and
the start task and exiting 4 (failed=0, skipped=5).

Real ansible runs the module: `virt.py` imports `libvirt` (then `lxml`)
at module level, declares `supports_check_mode=True`, and on a target
without the python bindings fails the task before any domain work:

```
[ERROR]: Task failed: Module failed: The `libvirt` module is not importable. Check the requirements.
fatal: [localhost]: FAILED! => {"changed": false, "msg": "The `libvirt` module is not importable. Check the requirements."}
```

The failed task halts the host, so the play ends there: `failed=1,
skipped=3` and exit 2. The deprecated `to_native` import that closes the
module's import block also makes real print its `[DEPRECATION WARNING]`
line.

krikri therefore routes the unported `virt` name to a synthesized import
gate on the target (same shape as the k8s and community.vmware gates),
which reproduces the failure, the library order and the deprecation
line. When both libraries do import, the module would go on to drive a
libvirt daemon krikri does not implement, so the designed
unavailable-module skip still applies.

## Case notes

The role is copied verbatim; its empty `virt_guest_disks` default makes
the three disk tasks loop over nothing, which is why both engines print
`skipping:` for them (`--check`, see `flags.txt`). The `virt` gate's
libraries are absent for the pinned `/usr/bin/python3` on the capture
host, which is what makes the failure reproducible in-process.
