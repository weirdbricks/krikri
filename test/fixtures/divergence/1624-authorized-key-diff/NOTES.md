# #1624 - kpg authorized_key (happy path): the `--diff` hunk is missing

- Issue: https://github.com/weirdbricks/krikri/issues/1624
- Playbook: `000010-multi-mysql_query-happy` (krikri-playbook-generator)
- Class: output gap (missing diff payload)

**What diverged.** The generator runs with `--diff`. Real's
`ansible.posix.authorized_key` builds `params['diff']` in enforce_state's
do_write branch (`before_header`/`after_header` = the resolved keyfile,
`before`/`after` = the file's old and new contents), so the callback prints
the `--- before: <keyfile>` / `+++ after: <keyfile>` hunk before `changed:`.
krikri's native authorized_key reported the change without any diff, so the
whole hunk was missing.

**Fixture.** The issue's `Authorized_key #10.1` task verbatim, with the
absolute `/tmp/kpg-work/authorized_keys` path replaced by
`{{ playbook_dir }}/authorized_keys` so the diff headers normalize to
`<WORK>`; `flags.txt` carries `--diff`, which is what makes the module build
the dict at all. `user: root` is the issue's own value (the module requires
`user` even with an explicit `path:`), and `manage_dir: "false"` keeps the
change to the single file.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`, from this directory.
