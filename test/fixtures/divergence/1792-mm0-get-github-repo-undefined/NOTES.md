# #1792 - mm0.clone-and-upload-git-repository: free-form local_action finalization block missing

- Issue: https://github.com/weirdbricks/krikri/issues/1792
- Role: mm0.clone-and-upload-git-repository (master)
- Class: output gap: the `[ERROR]: Task failed: Finalization of task args ...`
  chain block is missing in front of the fatal line

**What diverged.** The role's "Get github repo" task is a legacy free-form
directive, `local_action: git ... dest={{ temp_directory_local.path}}/{{ repo }} ...`,
and `repo` is set nowhere, so task-arg finalization fails. Real ansible (2.21.6)
prints the two-stanza chain: `Task failed.` Origin'd at the task's `name:` key,
then `Finalization of task args for 'ansible.builtin.git' failed: <inner
message>` Origin'd at the `git` module token that opens the directive's value,
with the full message on that middle stanza and no third stanza. krikri printed
only the fatal line.

**Why krikri dropped it.** The `[ERROR]` block renderer only recognised a
directive call (`action:`/`local_action: <module> <args>`) as such when the
module was one of the free-form RAW_COMMAND_MODULES (`command`/`shell`/...);
for any other module (`git` here) the flag stayed false, so it never looked for
the module token inside the directive's value and, finding no `git:` key line,
dropped the whole block. The same gate also collapsed a nameless directive
task's chain into the single-segment `Task failed: Finalization ... failed.`
shape real only uses for a plain `- <module>:` key.

**Fixture.** The failing task is the role's, copied verbatim; the role's
`tempfile`/`package`/`chmod` preamble only exists to produce
`temp_directory_local`, so this play supplies it as a var instead (nothing
outside the case's scratch directory is touched). `inventory.ini` pins the
interpreter on the local host. `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.
