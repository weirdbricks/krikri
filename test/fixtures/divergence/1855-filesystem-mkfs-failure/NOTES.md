# community.general.filesystem: mkfs failure shape

- issue: #1855 (https://github.com/weirdbricks/krikri/issues/1855)
- found by: `krikri-playbook-generator`, playbook `000010-multi-flatpak-happy`
  (krikri 0.9.3151)

## What diverged

The playbook's `Filesystem #10.1` task formats a zero-byte image, so mkfs
itself fails. Real `community.general.filesystem` runs every mkfs/wipefs
through `AnsibleModule.run_command(..., check_rc=True)`, whose `fail_json`
reports the tool's own stderr verbatim plus the command it ran:

```
fatal: [target -> target2]: FAILED! => {"changed": false, "cmd": "/usr/sbin/mkfs.ext2 -F -U okypgd /tmp/kpg-work/dest-0440.txt", "msg": "mke2fs 1.47.2 ...", "rc": 1, "stderr": "...", "stderr_lines": [...], "stdout": "", "stdout_lines": []}
```

krikri replaced that with its own wording and dropped the rest of the result:

```
fatal: [target -> target2]: FAILED! => {"changed": false, "msg": "mkfs.ext2 failed: mke2fs 1.47.2 ...\n\n"}
```

`uuid:` also never reached the command line, so the `cmd` value (and any
role reading `r.cmd`/`r.rc`/`r.stderr`) differed even before the message.

## Fix

`plugins/filesystem.cr` now mirrors `run_command`'s check_rc failure for both
the mkfs and the wipefs legs (`msg` = rstripped stderr, `cmd` = the
shlex-quoted argv with `get_bin_path`'s resolved executable, `rc`/`stdout`/
`stderr` and the `*_lines` lists), resolves the mkfs/wipefs binary the way
`get_bin_path(required=True)` does, and appends the per-fstype
`MKFS_SET_UUID_OPTIONS` pair to the create argv.

## Case adaptations

- `playbook.yml` is the issue's play with its single failing task verbatim,
  adapted only to localhost: `target2`'s delegation and the absolute
  `/tmp/kpg-work` path become this case's scratch directory (a task above it
  creates the zero-byte image).
- `stubbin/mkfs.ext2` plus `env.txt`'s PATH pin: a real mkfs names its own
  e2fsprogs version in the first stderr line, so no recording of a real one
  would replay on another host. The stub fails the same way, and the
  case-relative `./stubbin` entry resolves inside the case's scratch directory
  in both engines, so `cmd` is recorded as `./stubbin/mkfs.ext2 ...`.
- `inventory.ini` pins the interpreter on the `[local]` host.
- `expected.out` is a real ansible-core 2.21.6 capture
  (`bin/krikri-capture-case`).
