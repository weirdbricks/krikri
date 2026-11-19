# #1581 - jedimt.vcenter_ovf's OVA filename set_fact goes undefined in check mode

- Issue: https://github.com/weirdbricks/krikri/issues/1581
- Role: `jedimt.vcenter_ovf` (rocky host, round `round29917463`)
- Class: check-mode behavioural bug (a task failed on ansible and ran on krikri)

**What diverged.** In `--check`, `find` scans the not-yet-mounted ISO path and
registers an empty `files` list. The role then reads
`vcsa_ova_directory_contents.files[0].path.split('/')[-1]`. Real
ansible-core fails the arg finalization with the lazy template list's
"has no element 0" wording, so the play stops after `ok=5`/`failed=1`; krikri
rendered the whole chain to the `undefined` sentinel, reported the task `ok`,
and only failed on the NEXT task (where `vcsa_ova_filename` was the literal
string "undefined"), adding one more `ok` to the recap.

The root cause was the mid-chain empty-list index-0 probe: its plain-chain
gate only accepted `.attr`/`[index]` steps, so a method call anywhere in the
chain (`.split('/')`) made the probe decline and the strict failure was lost.

**Fixture.** The role's scan task plus both `set_fact` tasks verbatim
(`tasks/main.yml` lines 22-39), run with `--check` (flags.txt) since the
divergence only exists in check mode, where `find` cannot see a directory.
Only `vcenter_tmp_mount_dir` is adapted, to a path this box never has, so the
case does not depend on `/tmp/iso` state.
