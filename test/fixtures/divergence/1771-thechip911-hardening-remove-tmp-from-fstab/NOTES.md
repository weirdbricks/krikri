# #1771 - thechip911.hardening: "Remove /tmp from fstab" fails only on krikri

- Issue: https://github.com/weirdbricks/krikri/issues/1771
- Role: `thechip911.hardening` (ubuntu host, round `round29925782`)
- Class: a task failed on krikri where real ansible ran it

**What diverged.** The role's `ansible.posix.mount` task (`path: /tmp`,
`state: absent`, in its `tasks/fstab.yml`) reported `ok` under real
ansible-playbook and `fatal` under krikri:

```
Unsupported parameters for (ansible.posix.mount) module: __krikri_remote_tty.
Supported parameters include: backup, boot, dump, fstab, fstype, opts,
opts_no_log, passno, path, src, state (name).
```

`__krikri_remote_tty` is the executor's own marker for a remote dispatch
(it is what makes the spawn plugins manufacture the ssh transport's
controlling terminal, issue #1728). krikri's `mount` plugin hands every
task param to its own argument-spec rejection, and unlike the other
plugins that check it did not exempt engine-internal underscore-prefixed
keys - so on a remote connection the marker was reported as a user typo.
Real ansible never sees such a key, so real ran the task.

The role's task had to be pointed at a scratch mount point
(`/mnt/krikri1771` instead of `/tmp`) and a scratch fstab: real
ansible.posix.mount's `state: absent` unmounts a mounted path first, and
`/tmp` is mounted on the capturing host (it fails with "must be
superuser to unmount"). Everything else is the role's task verbatim.

**Why the stub transport.** The marker only exists on a NON-local
connection, and the corpus harness runs every case with `-c local`.
`flags.txt` therefore appends `-c ssh` (last flag wins) and
`inventory.ini` points `ansible_ssh_executable` at `fake-ssh`, which runs
the "remote" command on this same machine - the same shape the corpus's
`always-fail` stubs already use, only answering instead of failing. It
also satisfies scp's SFTP probe with a failed subsystem so OpenSSH scp
falls back to its legacy protocol (this box has no sftp-server); real
ansible transfers the module with `ansible_ssh_transfer_method=piped`.

**Fix.** `plugins/mount.cr` (with the same one-line exemption in
`replace.cr`, `deb822_repository.cr` and `docker_image_build.cr`, which
had the identical hole) now exempts every leading-underscore key from
the argument-spec rejection, matching what dnf/yum/systemd/lvg already
did. `test/integration/mount_test.cr` pins the mount side in-process.
