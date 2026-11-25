# #1818 - unarchive: the attribute pass dies on a member it just made unsearchable

- Issue: https://github.com/weirdbricks/krikri/issues/1818
- Role: `bbaassssiiee.wso2db` (ubuntu host, round `logs___1795626220`)
- Class: output gap (the failing task's `[ERROR]` chain and fatal result)

## What diverged

The role's "Unzip WSO2 API Manager Package" extracts the WSO2 API
Manager pack with `mode: u=rw,g=r,o=r`. Real ansible applies owner/group/
mode to every archive member in listing order, one member at a time: it
chmods the top directory into the requested mode (no search bit), and
then the first child of that directory can no longer be `lstat()`ed, so
main()'s attribute pass raises `OSError(EACCES)` into

```
[ERROR]: Task failed: Module failed: Unexpected error when accessing exploded file: [Errno 13] Permission denied: b'<abs dest>/wso2am-3.2.0/repository/conf/'
```

and fails with `msg: Unexpected error when accessing exploded file.`,
the exception text, and the extraction's own `res_args` (handler, dest,
src, extract_results, changed) plus the destination's stat block.

krikri batched the same pass into `find ... -exec chown/chgrp/chmod {} +`,
so the chmod hit the very same unreachable members (chmod visits find's
start arguments in order) but reported every one of them as its own raw
stderr line, in a message the module never produced:

```
[ERROR]: Task failed: Failed to set mode under files/packs/: chmod: cannot
access 'files/packs/wso2am-3.2.0/repository/conf': Permission denied
chmod: cannot access 'files/packs/wso2am-3.2.0/repository/deployment': ...
```

Two more differences rode along once the failure was reproduced here:
`extract_results.cmd` was a shell string in krikri vs real's argv list
with the resolved `/usr/bin/unzip` path, and the display layer had no
"Module failed." middle segment for this module-level `fail_json`.

## What this case pins

The role's "Unzip WSO2 API Manager Package" task, with the
`files/packs/` directory task that precedes it, adapted as described in
the playbook's own header (no `delegate_to:`/`connection:`/`run_once:`,
`{{ product_package_location }}` resolved to the case's own scratch path,
the get_url download replaced by a base64 seed of the archive checked in
here, `remote_src: true` so the reported `extract_results.cmd` does not
name a random `ansible-tmp` staging directory, and `dest:` a symlink to
the packs directory so real's closing `add_path_info(dest)` lstat()s the
link - its fixed mode/size/state - instead of a scratch directory whose
own `size` is the recording filesystem's). The zip carries the WSO2
pack's shape - a top directory plus nested `repository/` directories -
which is what makes the requested mode remove the search bit.

The case needs a non-root run: root's `chmod`/`lstat` bypass the missing
search bit, so both engines would succeed (like the round's host, the
suite runs unprivileged), and the replay skips when it finds itself
running as root.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6. `archive.b64` is the fixture archive, not a
recording.
